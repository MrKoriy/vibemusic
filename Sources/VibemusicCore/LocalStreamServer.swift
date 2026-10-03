import Foundation
import Network
import os

private let networkLogger = Logger(subsystem: "com.vibemusic.app", category: "network")

/// Ограничивает число одновременно запущенных curl-процессов. Актор вместо
/// DispatchSemaphore: ожидание слота не блокирует потоки кооперативного пула.
private actor CurlSlotLimiter {
    private var freeSlots: Int
    private var nextTicket = 0
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]

    init(limit: Int) {
        freeSlots = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        guard freeSlots == 0 else {
            freeSlots -= 1
            return
        }
        let ticket = nextTicket
        nextTicket += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters[ticket] = continuation
            }
        } onCancel: {
            Task { await self.dropWaiter(ticket: ticket) }
        }
    }

    func release() {
        guard let first = waiters.keys.min(),
              let waiter = waiters.removeValue(forKey: first) else {
            freeSlots += 1
            return
        }
        waiter.resume()
    }

    private func dropWaiter(ticket: Int) {
        if let waiter = waiters.removeValue(forKey: ticket) {
            waiter.resume(throwing: URLError(.cancelled))
        }
    }
}

/// Загрузка через системный curl. Нужна, потому что URLSession не умеет
/// SOCKS5 с авторизацией, а AVPlayer-совместимый стриминг идёт через
/// Range-запросы к googlevideo.
enum CurlFetcher {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static let maxConcurrentProcesses = 4
    private static let limiter = CurlSlotLimiter(limit: maxConcurrentProcesses)
    private static let watchdogQueue = DispatchQueue(label: "vibemusic.curl.watchdog")

    /// Асинхронная загрузка: максимум `maxConcurrentProcesses` параллельных
    /// curl-процессов, кооперативная отмена задачи завершает процесс.
    static func fetch(
        url: URL,
        range: (start: Int64, end: Int64)? = nil,
        proxy: String? = nil,
        timeout: TimeInterval
    ) async throws -> Response {
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let response = try await runCurlProcess(url: url, range: range, proxy: proxy, timeout: timeout)
            await limiter.release()
            return response
        } catch {
            await limiter.release()
            throw error
        }
    }

    private static func runCurlProcess(
        url: URL,
        range: (start: Int64, end: Int64)?,
        proxy: String?,
        timeout: TimeInterval
    ) async throws -> Response {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibemusic-curl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let headerPath = workDir.appendingPathComponent("headers").path
        let bodyPath = workDir.appendingPathComponent("body").path

        var arguments = [
            "-sS", "-L",
            // Только http(s), в том числе для редиректов.
            "--proto", "=http,https",
            "--proto-redir", "=http,https",
            "-m", String(Int(timeout)),
            "-A", LocalStream.userAgent,
            "-D", headerPath,
            "-o", bodyPath,
        ]
        // Прокси (с логином/паролем) — через конфиг на stdin, а не в argv:
        // argv любого процесса виден всем локальным пользователям через `ps`.
        var stdinConfig: Data?
        if let proxy {
            guard let line = configLine(proxy: proxy) else { throw URLError(.badURL) }
            stdinConfig = Data(line.utf8)
            arguments += ["-K", "-"]
        }
        if let range {
            arguments += ["-r", "\(range.start)-\(range.end)"]
        }
        arguments.append(url.absoluteString)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        let stdinPipe: Pipe? = stdinConfig == nil ? nil : Pipe()
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        watchdogQueue.asyncAfter(deadline: .now() + timeout + 10, execute: watchdog)
        defer { watchdog.cancel() }

        // terminationHandler регистрируется до run(): даже мгновенный выход
        // процесса гарантированно возобновит продолжение.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                    if let stdinPipe, let stdinConfig {
                        // Конфиг крошечный (меньше буфера пайпа) — запись не блокирует.
                        stdinPipe.fileHandleForWriting.write(stdinConfig)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled {
            throw URLError(.cancelled)
        }

        let body = (try? Data(contentsOf: URL(fileURLWithPath: bodyPath))) ?? Data()
        let headerDump = (try? String(contentsOf: URL(fileURLWithPath: headerPath), encoding: .utf8)) ?? ""

        guard process.terminationStatus == 0 else {
            networkLogger.warning("curl exited with code \(process.terminationStatus, privacy: .public)")
            throw mapError(exitCode: process.terminationStatus)
        }
        let parsed = parse(headerDump: headerDump)
        return Response(status: parsed.status, headers: parsed.headers, body: body)
    }

    /// Строка конфига curl (`-K`) с прокси. Значение в двойных кавычках,
    /// `\` и `"` экранируются. nil — если в URL есть перевод строки или NUL.
    static func configLine(proxy: String) -> String? {
        guard !proxy.isEmpty,
              proxy.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r\u{0}")) == nil else { return nil }
        let escaped = proxy
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "proxy = \"\(escaped)\"\n"
    }

    /// Разбирает дамп заголовков curl (-D). При редиректах curl пишет несколько
    /// ответов подряд — берём последний, заголовки редиректа не должны протекать.
    static func parse(headerDump: String) -> (status: Int, headers: [String: String]) {
        var status = 0
        var headers: [String: String] = [:]
        let blocks = headerDump.components(separatedBy: "\r\n\r\n")
        for block in blocks where block.contains("HTTP/") {
            let lines = block.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            guard let first = lines.first else { continue }
            let parts = first.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                status = code
            }
            headers = [:]
            for line in lines.dropFirst() {
                let keyValue = line.split(separator: ":", maxSplits: 1)
                if keyValue.count == 2 {
                    let key = keyValue[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = keyValue[1].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
        }
        return (status, headers)
    }

    static func mapError(exitCode: Int32) -> URLError {
        switch exitCode {
        case 28:
            return URLError(.timedOut)
        case 5, 6, 7, 35, 56, 97:
            return URLError(.cannotConnectToHost)
        default:
            return URLError(.badServerResponse)
        }
    }
}

/// Handle for NWListener startup — supports both sync (legacy) and async waiting.
public final class AsyncStartHandle: @unchecked Sendable {
    var listener: NWListener?
    private let lock = NSLock()
    private var port: UInt16?
    private var error: Error?
    private var continuations: [CheckedContinuation<UInt16, Error>] = []
    private let semaphore = DispatchSemaphore(value: 0)

    static var alreadyReady: AsyncStartHandle { AsyncStartHandle() }

    static func ready(port: UInt16) -> AsyncStartHandle {
        let h = AsyncStartHandle()
        h.lock.lock()
        h.port = port
        h.lock.unlock()
        h.semaphore.signal()
        return h
    }

    func complete(port: UInt16) {
        lock.lock()
        self.port = port
        let conts = continuations
        continuations.removeAll()
        lock.unlock()
        semaphore.signal()
        for c in conts { c.resume(returning: port) }
    }

    func fail(error: Error) {
        lock.lock()
        self.error = error
        let conts = continuations
        continuations.removeAll()
        lock.unlock()
        semaphore.signal()
        for c in conts { c.resume(throwing: error) }
    }

    func waitForResult(timeout: TimeInterval) throws -> UInt16 {
        let result = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        if let p = port { return p }
        if let e = error { throw e }
        if result == .timedOut { throw URLError(.timedOut) }
        return port ?? 0
    }

    private func peekResult() -> Result<UInt16, Error>? {
        lock.lock(); defer { lock.unlock() }
        if let p = port { return .success(p) }
        if let e = error { return .failure(e) }
        return nil
    }

    private func registerContinuation(_ cont: CheckedContinuation<UInt16, Error>) -> Result<UInt16, Error>? {
        lock.lock(); defer { lock.unlock() }
        if let p = port { return .success(p) }
        if let e = error { return .failure(e) }
        continuations.append(cont)
        return nil
    }

    func waitAsync() async throws -> UInt16 {
        if let r = peekResult() {
            switch r { case .success(let p): return p; case .failure(let e): throw e }
        }
        return try await withCheckedThrowingContinuation { cont in
            if let r = self.registerContinuation(cont) {
                switch r {
                case .success(let p): cont.resume(returning: p)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }
}

/// Локальный HTTP-сервер для AVPlayer.
/// Проблема: googlevideo троттлит open-ended Range-запросы (~27 КБ/с) и
/// придирчив к User-Agent, а AVAssetResourceLoaderDelegate заставляет AVPlayer
/// вести себя нестабильно. Решение: AVPlayer играет обычный HTTP URL с
/// 127.0.0.1, сервер тянет у googlevideo bounded-чанки (без троттлинга)
/// с браузерным UA, кэширует их и раздаёт.
public final class StreamHub: @unchecked Sendable {
    public static let shared = StreamHub()

    let handlerQueue = DispatchQueue(label: "vibemusic.streamhub.conn")

    private let startLock = NSLock()
    private var listener: NWListener?
    private var serverPort: UInt16 = 0
    private var pendingHandle: AsyncStartHandle?

    private let streamsLock = NSLock()
    private var streams: [String: LocalStream] = [:]

    private static let debugEnabled = ProcessInfo.processInfo.environment["VIBEMUSIC_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let t = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
        FileHandle.standardError.write(Data(String(format: "[hub %7.2f] %@\n", t, message()).utf8))
    }

    public func start() throws {
        startLock.lock()
        if serverPort != 0 { startLock.unlock(); return }
        if let pending = pendingHandle {
            startLock.unlock()
            do {
                let p = try pending.waitForResult(timeout: 5)
                if p != 0 { claimStart(port: p, handle: pending) }
                return
            } catch {
                clearPendingIfMatch(pending)
                throw error
            }
        }
        startLock.unlock()
        let handle = try startAsync()
        do {
            let port = try handle.waitForResult(timeout: 5)
            guard port != 0 else { clearPendingIfMatch(handle); return }
            claimStart(port: port, handle: handle)
        } catch {
            clearPendingIfMatch(handle)
            throw error
        }
    }

    /// Async variant: waits for NWListener without blocking the caller's thread
    /// via semaphore under the hood only when called from non-async context.
    /// Prefer `startAsync()` from async call sites to avoid any blocking.
    public func startAsync() throws -> AsyncStartHandle {
        startLock.lock()
        if serverPort != 0 {
            let p = serverPort
            startLock.unlock()
            return AsyncStartHandle.ready(port: p)
        }
        if let pending = pendingHandle { startLock.unlock(); return pending }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        let handle = AsyncStartHandle()
        listener.stateUpdateHandler = { [weak handle] state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                handle?.complete(port: port)
            case .failed(let error):
                handle?.fail(error: error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: handlerQueue)
        handle.listener = listener
        pendingHandle = handle
        startLock.unlock()

        // Synchronous wait — only for legacy sync callers. Async callers
        // should use `await handle.waitAsync()` pattern via `openStreamAsync`.
        return handle
    }

    private func checkStarted() -> Bool {
        startLock.lock(); defer { startLock.unlock() }
        return serverPort != 0
    }

    private func claimStart(port: UInt16, handle: AsyncStartHandle) {
        startLock.lock(); defer { startLock.unlock() }
        if serverPort == 0 {
            serverPort = port
            listener = handle.listener
            pendingHandle = nil
            Self.log("server ready on 127.0.0.1:\(port)")
        } else if pendingHandle === handle {
            pendingHandle = nil
        }
    }

    private func clearPendingIfMatch(_ handle: AsyncStartHandle) {
        startLock.lock(); defer { startLock.unlock() }
        if pendingHandle === handle { pendingHandle = nil }
    }

    /// Waits for listener readiness asynchronously — does not block a thread.
    public func ensureStarted() async throws {
        if checkStarted() { return }
        let handle = try startAsync()
        do {
            let port = try await handle.waitAsync()
            claimStart(port: port, handle: handle)
        } catch {
            clearPendingIfMatch(handle)
            throw error
        }
    }

    private func finalizeStart(handle: AsyncStartHandle, port: UInt16) {
        startLock.lock()
        if serverPort == 0 {
            serverPort = port
            listener = handle.listener
            pendingHandle = nil
            Self.log("server ready on 127.0.0.1:\(port)")
        } else if pendingHandle === handle {
            pendingHandle = nil
        }
        startLock.unlock()
    }

    @discardableResult
    public func openStream(
        upstream: URL,
        proxy: String? = nil,
        refresher: LocalStream.UpstreamRefresher? = nil
    ) throws -> LocalStream {
        // If already started, fast path; otherwise block briefly (CLI / legacy).
        if serverPort == 0 {
            let handle = try startAsync()
            let port: UInt16
            do {
                port = try handle.waitForResult(timeout: 5)
            } catch {
                clearPendingIfMatch(handle)
                throw NSError(
                    domain: "StreamHub",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить локальный потоковый сервер: \(error.localizedDescription)"]
                )
            }
            guard port != 0 else {
                clearPendingIfMatch(handle)
                throw NSError(
                    domain: "StreamHub",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить локальный потоковый сервер"]
                )
            }
            finalizeStart(handle: handle, port: port)
        }
        let stream = LocalStream(upstream: upstream, port: serverPort, proxyURL: proxy, refresher: refresher)
        streamsLock.lock()
        streams[stream.token] = stream
        streamsLock.unlock()
        Self.log("stream \(stream.token.prefix(8)) -> \(upstream.host ?? "?")\(proxy != nil ? " [proxy]" : "")")
        networkLogger.info("stream opened token=\(String(stream.token.prefix(8)), privacy: .public) proxy=\(proxy != nil, privacy: .public)")
        return stream
    }

    public func closeStream(_ stream: LocalStream) {
        streamsLock.lock()
        streams.removeValue(forKey: stream.token)
        streamsLock.unlock()
        stream.close()
        networkLogger.info("stream closed token=\(String(stream.token.prefix(8)), privacy: .public)")
    }

    func stream(for token: String) -> LocalStream? {
        streamsLock.lock()
        defer { streamsLock.unlock() }
        return streams[token]
    }

    /// Аудит B-3: deny-by-default — соединение без remoteEndpoint или не с
    /// loopback-адреса отклоняется. Сервер слушает только 127.0.0.1, но
    /// проверка защищает от будущих изменений привязки.
    private func accept(_ connection: NWConnection) {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, _) = endpoint,
              Self.isLoopbackHost(host) else {
            networkLogger.notice("rejected connection without loopback endpoint")
            connection.cancel()
            return
        }
        networkLogger.debug("accepted loopback connection")
        HTTPConnectionHandler(connection: connection, hub: self).run()
    }

    static func isLoopbackHost(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            return address == .loopback
        default:
            return false
        }
    }
}

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

// MARK: - HTTP

/// Разобранный Range-заголовок.
enum RangeSpec: Equatable {
    /// bytes=start-end или bytes=start-
    case offset(start: Int64, end: Int64?)
    /// bytes=-N — последние N байт файла (разрешается после ensureTotal)
    case suffix(length: Int64)
}

final class HTTPConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let hub: StreamHub
    private var buffer = Data()
    private var pumpTask: Task<Void, Never>?
    private var isFinished = false

    init(connection: NWConnection, hub: StreamHub) {
        self.connection = connection
        self.hub = hub
    }

    func run() {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveMore()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: hub.handlerQueue)
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data {
                self.buffer.append(data)
            }
            if error != nil {
                self.finish()
                return
            }
            if let terminator = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = self.buffer.subdata(in: 0..<terminator.upperBound)
                self.handle(headerData: headerData)
            } else if self.buffer.count > 65536 {
                self.respondSimple(status: "404 Not Found")
            } else {
                self.receiveMore()
            }
        }
    }

    private func handle(headerData: Data) {
        guard let text = String(data: headerData, encoding: .utf8) else {
            respondSimple(status: "404 Not Found")
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respondSimple(status: "404 Not Found")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respondSimple(status: "405 Method Not Allowed")
            return
        }
        let path = String(parts[1])
        let token = path.dropFirst().split(separator: ".").first.map(String.init) ?? ""

        var rangeHeader: String?
        for line in lines.dropFirst() {
            let keyValue = line.split(separator: ":", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            if keyValue[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                rangeHeader = keyValue[1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard let stream = hub.stream(for: token) else {
            respondSimple(status: "404 Not Found")
            return
        }
        let range = rangeHeader.flatMap(Self.parseRange)
        StreamHub.log("request token=\(token.prefix(8)) range=\(rangeHeader ?? "none")")
        networkLogger.debug("request token=\(String(token.prefix(8)), privacy: .public) range=\(rangeHeader ?? "none", privacy: .public)")

        pumpTask = Task {
            await self.serve(stream: stream, range: range)
        }
    }

    /// Аудит B-4: поддерживает bounded (bytes=0-99), open-ended (bytes=100-)
    /// и суффиксный (bytes=-500) синтаксис. Невалидные строки → nil.
    static func parseRange(_ value: String) -> RangeSpec? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let startText = bounds[0].trimmingCharacters(in: .whitespaces)
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let length = Int64(endText), length > 0 else { return nil }
            return .suffix(length: length)
        }
        guard let start = Int64(startText), start >= 0 else { return nil }
        let end = endText.isEmpty ? nil : Int64(endText)
        return .offset(start: start, end: end)
    }

    /// Разрешает RangeSpec в конкретные (start, end) при известном total.
    /// Суффикс N > total → весь файл.
    static func resolvedBounds(_ spec: RangeSpec?, total: Int64) -> (start: Int64, end: Int64) {
        switch spec {
        case nil:
            return (0, total - 1)
        case .suffix(let length):
            let count = min(length, total)
            return (total - count, total - 1)
        case .offset(let start, let end):
            let upperBound = min(end ?? (total - 1), total - 1)
            return (start, upperBound)
        }
    }

    /// Content-Type для ответа клиенту: реальный тип upstream с вырезанными
    /// переводами строк (защита от подделки заголовков), дефолт — audio/mp4.
    static func sanitizedContentType(_ value: String) -> String {
        let cleaned = value
            .components(separatedBy: .newlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? LocalStream.defaultContentType : cleaned
    }

    private func serve(stream: LocalStream, range: RangeSpec?) async {
        do {
            let total = try await stream.ensureTotal()
            guard total > 0 else {
                respondSimple(status: "404 Not Found")
                return
            }

            let resolved = Self.resolvedBounds(range, total: total)
            let start = resolved.start
            let end = resolved.end
            guard start >= 0, start <= end else {
                respond416(total: total)
                return
            }

            let length = end - start + 1
            var head = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\n"
            head += "Content-Type: \(Self.sanitizedContentType(stream.resolvedContentType()))\r\n"
            if range != nil {
                head += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
            }
            head += "Content-Length: \(length)\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Connection: close\r\n\r\n"
            try await send(Data(head.utf8))

            var cursor = start
            while cursor <= end {
                try Task.checkCancellation()
                let chunk = try await stream.fetchChunk(offset: cursor)
                let lower = stream.chunkLowerBound(cursor)
                let inChunk = Int(cursor - lower)
                let available = Int64(chunk.count) - Int64(inChunk)
                guard available > 0 else { throw URLError(.badServerResponse) }
                let take = min(available, end - cursor + 1)
                try await send(chunk.subdata(in: inChunk..<inChunk + Int(take)))
                cursor += take
            }
        } catch {
            StreamHub.log("serve error: \(error.localizedDescription)")
            networkLogger.error("serve failed: \(error.localizedDescription)")
        }
        finish()
    }

    private func respond416(total: Int64) {
        let head = "HTTP/1.1 416 Range Not Satisfiable\r\n"
            + "Content-Range: bytes */\(total)\r\n"
            + "Content-Length: 0\r\n"
            + "Connection: close\r\n\r\n"
        pumpTask = Task {
            try? await self.send(Data(head.utf8))
            self.finish()
        }
    }

    private func respondSimple(status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        pumpTask = Task {
            try? await self.send(Data(head.utf8))
            self.finish()
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Разрывает цикл удержания connection → stateUpdateHandler → self → connection.
    /// Идемпотентен: безопасно вызывать из любого места и несколько раз.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        pumpTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
