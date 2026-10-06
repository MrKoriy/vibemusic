import Foundation
import os

public final class LocalStream: @unchecked Sendable {
    /// Повторный резолв ссылки тем же маршрутом (прокси/напрямую).
    public typealias UpstreamRefresher = @Sendable () async throws -> URL

    /// Ошибка HTTP от upstream: 403/410 у googlevideo = ссылка протухла.
    struct UpstreamHTTPError: Error, Equatable {
        let status: Int
        var isExpiredLink: Bool { status == 403 || status == 410 }
    }

    public let token = UUID().uuidString
    public let localURL: URL
    /// Текущая ссылка upstream. Меняется, когда googlevideo-ссылка истекает
    /// (≈6 ч): многочасовые треки для сна раньше обрывались на 403.
    public var upstream: URL {
        lock.lock()
        defer { lock.unlock() }
        return currentUpstream
    }

    /// Обновляем ссылку заранее, если до истечения осталось меньше этого.
    static let refreshLeadTime: TimeInterval = 120
    /// Не чаще одного резолва в этот интервал — защита от цикла 403 → резолв → 403.
    static let minRefreshInterval: TimeInterval = 30

    static let chunkSize: Int64 = 1_048_576
    static let maxCacheBytes: Int64 = 48 * 1_048_576
    static let defaultContentType = "audio/mp4"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private let session: URLSession
    private let proxyURL: String?
    private let cacheLimitBytes: Int64
    private let lock = NSLock()
    private var cache: [Int64: Data] = [:]
    private var cacheBytes: Int64 = 0
    private var cacheOrder: [Int64: UInt64] = [:]
    private var cacheClock: UInt64 = 0
    private var totalLength: Int64?
    private var contentType: String?
    private var inflight: [Int64: ChunkTask] = [:]
    private var closed = false
    private var currentUpstream: URL
    private let refresher: UpstreamRefresher?
    private var refreshTask: Task<URL, Error>?
    private var lastRefreshAt: Date?

    private final class ChunkTask {
        let id = UUID()
        let task: Task<Data, Error>
        init(task: Task<Data, Error>) { self.task = task }
    }

    init(
        upstream: URL,
        port: UInt16,
        proxyURL: String? = nil,
        maxCacheBytes: Int64 = LocalStream.maxCacheBytes,
        refresher: UpstreamRefresher? = nil
    ) {
        self.currentUpstream = upstream
        self.refresher = refresher
        self.proxyURL = proxyURL
        self.cacheLimitBytes = maxCacheBytes
        self.localURL = URL(string: "http://127.0.0.1:\(port)/\(token).m4a")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 86_400
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept": "*/*",
        ]
        session = URLSession(configuration: config)
    }

    func close() {
        lock.lock()
        closed = true
        let tasks = inflight.values.map(\.task)
        let pendingRefresh = refreshTask
        refreshTask = nil
        inflight.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        lock.unlock()
        tasks.forEach { $0.cancel() }
        pendingRefresh?.cancel()
        session.finishTasksAndInvalidate()
        StreamHub.log("stream \(token.prefix(8)) closed")
    }

    // MARK: - Диапазоны и кэш

    func chunkLowerBound(_ offset: Int64) -> Int64 {
        (offset / Self.chunkSize) * Self.chunkSize
    }

    func total() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return totalLength
    }

    private func setTotal(_ value: Int64) {
        lock.lock()
        if totalLength == nil { totalLength = value }
        lock.unlock()
    }

    /// Начало диапазона из Content-Range: «bytes 100-199/1000» → 100.
    static func parseRangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst(6)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dash].trimmingCharacters(in: .whitespaces))
    }

    /// Байты чанка с началом `lower` из ответа upstream.
    /// 206 — принимается, только если Content-Range начинается с `lower`.
    /// 200 — upstream проигнорировал Range и прислал файл целиком:
    /// нужный кусок вырезается по смещению (раньше в чанк попадали байты
    /// с начала файла — звук ломался). Иначе — nil.
    static func chunkPayload(status: Int, contentRange: String?, body: Data, lower: Int64) -> Data? {
        guard !body.isEmpty, lower >= 0 else { return nil }
        let size = Int(chunkSize)
        switch status {
        case 206:
            if let contentRange, let start = parseRangeStart(contentRange), start != lower {
                return nil
            }
            return Data(body.prefix(size))
        case 200:
            guard lower < Int64(body.count) else { return nil }
            let from = body.startIndex + Int(lower)
            let to = min(body.endIndex, from + size)
            return body.subdata(in: from..<to)
        default:
            return nil
        }
    }

    static func parseTotal(_ header: String) -> Int64? {
        guard let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    var cachedChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    var cachedChunkBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return cacheBytes
    }

    /// Читает чанк из кэша, обновляя время последнего использования (LRU).
    func cachedData(forChunk lower: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let data = cache[lower] else { return nil }
        cacheClock += 1
        cacheOrder[lower] = cacheClock
        return data
    }

    func storeCache(chunkLower: Int64, data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let existing = cache[chunkLower] {
            cacheBytes -= Int64(existing.count)
        }
        cache[chunkLower] = data
        cacheBytes += Int64(data.count)
        cacheClock += 1
        cacheOrder[chunkLower] = cacheClock
        // Аудит B-7: при превышении лимита вытесняется самая давно
        // использованная запись, а не минимальный оффсет.
        while cacheBytes > cacheLimitBytes, let lru = leastRecentlyUsedChunk() {
            cacheOrder.removeValue(forKey: lru)
            if let removed = cache.removeValue(forKey: lru) {
                cacheBytes -= Int64(removed.count)
            }
        }
        lock.unlock()
    }

    private func leastRecentlyUsedChunk() -> Int64? {
        cacheOrder.min { $0.value < $1.value }?.key
    }

    // MARK: - Content-Type

    /// Запоминает Content-Type из ответа upstream; первый ответ выигрывает.
    func recordContentType(_ value: String?) {
        guard let value else { return }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        lock.lock()
        if contentType == nil { contentType = cleaned }
        lock.unlock()
    }

    func resolvedContentType() -> String {
        lock.lock()
        defer { lock.unlock() }
        return contentType ?? Self.defaultContentType
    }

    // MARK: - Загрузка чанков

    func ensureTotal() async throws -> Int64 {
        if let known = total() { return known }
        if let proxyURL {
            let response = try await CurlFetcher.fetch(url: try await usableUpstream(), range: (0, 1), proxy: proxyURL, timeout: 20)
            guard (200...299).contains(response.status) else {
                throw URLError(.badServerResponse)
            }
            recordContentType(response.headers["content-type"])
            if let rangeHeader = response.headers["content-range"],
               let parsed = Self.parseTotal(rangeHeader) {
                setTotal(parsed)
                return parsed
            }
            if response.status == 200,
               let lengthHeader = response.headers["content-length"],
               let parsed = Int64(lengthHeader) {
                setTotal(parsed)
                return parsed
            }
            throw URLError(.badServerResponse)
        }
        var request = URLRequest(url: try await usableUpstream())
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        recordContentType(http.value(forHTTPHeaderField: "Content-Type"))
        if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
           let parsed = Self.parseTotal(rangeHeader) {
            setTotal(parsed)
            return parsed
        }
        if http.statusCode == 200, http.expectedContentLength > 0 {
            setTotal(http.expectedContentLength)
            return http.expectedContentLength
        }
        throw URLError(.badServerResponse)
    }

    func fetchChunk(offset: Int64) async throws -> Data {
        let lower = chunkLowerBound(offset)
        if let cached = cachedData(forChunk: lower) {
            StreamHub.log("cache hit chunk=\(lower)")
            return cached
        }

        let entry: ChunkTask
        let existing = takeOrRegisterInflight(chunkLower: lower)
        switch existing {
        case .closed:
            throw URLError(.cancelled)
        case .existing(let found):
            entry = found
        case .created(let created):
            entry = created
        }
        defer { removeInflightWhenDone(chunkLower: lower, id: entry.id) }
        return try await entry.task.value
    }

    private enum InflightOutcome {
        case closed
        case existing(ChunkTask)
        case created(ChunkTask)
    }

    private func takeOrRegisterInflight(chunkLower: Int64) -> InflightOutcome {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        if let found = inflight[chunkLower] { return .existing(found) }
        let created = ChunkTask(task: Task<Data, Error> { [weak self] in
            guard let self else { throw URLError(.cancelled) }
            return try await self.downloadChunk(lower: chunkLower)
        })
        inflight[chunkLower] = created
        return .created(created)
    }

    private func removeInflightWhenDone(chunkLower: Int64, id: UUID) {
        lock.lock()
        if let current = inflight[chunkLower], current.id == id {
            inflight.removeValue(forKey: chunkLower)
        }
        lock.unlock()
    }

    // MARK: - Обновление протухшей ссылки

    /// Ссылка для запроса: если она вот-вот истечёт — сначала обновляем.
    func usableUpstream(now: Date = Date()) async throws -> URL {
        let url = upstream
        guard refresher != nil,
              let expiry = StreamURLCache.parseExpiry(from: url),
              expiry - now.timeIntervalSince1970 < Self.refreshLeadTime else {
            return url
        }
        return try await refreshUpstream(replacing: url)
    }

    /// Резолвит ссылку заново. Параллельные запросы чанков ждут один общий
    /// резолв; если ссылку уже обновили — сразу возвращается новая.
    func refreshUpstream(replacing failed: URL) async throws -> URL {
        switch beginRefresh(replacing: failed) {
        case .alreadyRefreshed(let url):
            return url
        case .unavailable:
            throw UpstreamHTTPError(status: 403)
        case .wait(let task):
            do {
                let url = try await task.value
                // Другой формат (itag/размер) = другие байты: склеивать нельзя.
                guard Self.isSameMedia(failed, url) else {
                    finishRefresh(task: task, result: nil)
                    throw UpstreamHTTPError(status: 409)
                }
                finishRefresh(task: task, result: url)
                return url
            } catch {
                finishRefresh(task: task, result: nil)
                throw error
            }
        }
    }

    /// Ссылки на один и тот же поток: совпадают itag и clen, если они есть.
    static func isSameMedia(_ a: URL, _ b: URL) -> Bool {
        func params(_ url: URL) -> [String: String] {
            var result: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if let value = item.value { result[item.name] = value }
            }
            return result
        }
        let pa = params(a)
        let pb = params(b)
        for key in ["itag", "clen"] {
            if let va = pa[key], let vb = pb[key], va != vb { return false }
        }
        return true
    }

    private enum RefreshStart {
        case alreadyRefreshed(URL)
        case unavailable
        case wait(Task<URL, Error>)
    }

    private func beginRefresh(replacing failed: URL) -> RefreshStart {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .unavailable }
        if currentUpstream != failed { return .alreadyRefreshed(currentUpstream) }
        if let refreshTask { return .wait(refreshTask) }
        guard let refresher else { return .unavailable }
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < Self.minRefreshInterval {
            return .unavailable
        }
        let task = Task<URL, Error> { try await refresher() }
        refreshTask = task
        lastRefreshAt = Date()
        return .wait(task)
    }

    private func finishRefresh(task: Task<URL, Error>, result: URL?) {
        lock.lock()
        let isCurrent = refreshTask.map { $0 == task } ?? false
        if isCurrent {
            refreshTask = nil
            if let result, !closed {
                currentUpstream = result
            }
        }
        lock.unlock()
        if isCurrent, result != nil {
            StreamHub.log("stream \(token.prefix(8)) upstream refreshed")
            networkLogger.info("stream upstream refreshed token=\(String(self.token.prefix(8)), privacy: .public)")
        }
    }

    private func downloadChunk(lower: Int64) async throws -> Data {
        let url = try await usableUpstream()
        do {
            return try await downloadChunk(lower: lower, from: url)
        } catch let error as UpstreamHTTPError where error.isExpiredLink && refresher != nil {
            // Ссылка истекла (долгая пауза, многочасовой трек) — резолвим заново
            // и продолжаем с того же места, без переключения трека.
            networkLogger.warning("upstream \(error.status, privacy: .public), обновляю ссылку")
            let fresh = try await refreshUpstream(replacing: url)
            return try await downloadChunk(lower: lower, from: fresh)
        }
    }

    private func downloadChunk(lower: Int64, from upstream: URL) async throws -> Data {
        var upper = lower + Self.chunkSize - 1
        if let total = total() {
            upper = min(upper, total - 1)
        }
        if let proxyURL {
            let response = try await CurlFetcher.fetch(
                url: upstream,
                range: (lower, upper),
                proxy: proxyURL,
                timeout: 45
            )
            if response.status >= 400 {
                throw UpstreamHTTPError(status: response.status)
            }
            let contentRange = response.headers["content-range"]
            guard let payload = Self.chunkPayload(
                status: response.status,
                contentRange: contentRange,
                body: response.body,
                lower: lower
            ) else {
                throw URLError(.badServerResponse)
            }
            recordContentType(response.headers["content-type"])
            if let contentRange, let parsed = Self.parseTotal(contentRange), total() == nil {
                setTotal(parsed)
            }
            storeCache(chunkLower: lower, data: payload)
            StreamHub.log("chunk \(lower)-\(lower + Int64(payload.count) - 1) via curl (\(payload.count) bytes)")
            networkLogger.debug("chunk fetched offset=\(lower, privacy: .public) bytes=\(payload.count, privacy: .public) via curl")
            return payload
        }
        var request = URLRequest(url: upstream)
        request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode >= 400 {
            throw UpstreamHTTPError(status: http.statusCode)
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        guard let payload = Self.chunkPayload(
            status: http.statusCode,
            contentRange: contentRange,
            body: data,
            lower: lower
        ) else {
            throw URLError(.badServerResponse)
        }
        recordContentType(http.value(forHTTPHeaderField: "Content-Type"))
        if let contentRange, let parsed = Self.parseTotal(contentRange), total() == nil {
            setTotal(parsed)
        }
        storeCache(chunkLower: lower, data: payload)
        StreamHub.log("chunk \(lower)-\(lower + Int64(payload.count) - 1) fetched (\(payload.count) bytes)")
        networkLogger.debug("chunk fetched offset=\(lower, privacy: .public) bytes=\(payload.count, privacy: .public)")
        return payload
    }
}

