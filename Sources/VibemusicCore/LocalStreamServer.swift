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
            "-m", String(Int(timeout)),
            "-A", LocalStream.userAgent,
            "-D", headerPath,
            "-o", bodyPath,
        ]
        if let proxy {
            arguments += ["-x", proxy]
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
        defer { startLock.unlock() }
        if serverPort != 0 { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        let semaphore = DispatchSemaphore(value: 0)
        final class PortBox: @unchecked Sendable { var value: UInt16 = 0 }
        let portBox = PortBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                portBox.value = listener.port?.rawValue ?? 0
                semaphore.signal()
            case .failed:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: handlerQueue)
        _ = semaphore.wait(timeout: .now() + 5)

        guard portBox.value != 0 else {
            throw NSError(
                domain: "StreamHub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить локальный потоковый сервер"]
            )
        }
        serverPort = portBox.value
        self.listener = listener
        Self.log("server ready on 127.0.0.1:\(portBox.value)")
    }

    @discardableResult
    public func openStream(upstream: URL, proxy: String? = nil) throws -> LocalStream {
        try start()
        let stream = LocalStream(upstream: upstream, port: serverPort, proxyURL: proxy)
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
    public let token = UUID().uuidString
    public let upstream: URL
    public let localURL: URL

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

    private final class ChunkTask {
        let id = UUID()
        let task: Task<Data, Error>
        init(task: Task<Data, Error>) { self.task = task }
    }

    init(upstream: URL, port: UInt16, proxyURL: String? = nil, maxCacheBytes: Int64 = LocalStream.maxCacheBytes) {
        self.upstream = upstream
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
        inflight.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        lock.unlock()
        tasks.forEach { $0.cancel() }
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
            let response = try await CurlFetcher.fetch(url: upstream, range: (0, 1), proxy: proxyURL, timeout: 20)
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
        var request = URLRequest(url: upstream)
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

    private func downloadChunk(lower: Int64) async throws -> Data {
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
            guard (200...299).contains(response.status), !response.body.isEmpty else {
                throw URLError(.badServerResponse)
            }
            recordContentType(response.headers["content-type"])
            if let rangeHeader = response.headers["content-range"],
               let parsed = Self.parseTotal(rangeHeader), total() == nil {
                setTotal(parsed)
            }
            let capped = response.body.prefix(Int(Self.chunkSize))
            storeCache(chunkLower: lower, data: Data(capped))
            StreamHub.log("chunk \(lower)-\(lower + Int64(capped.count) - 1) via curl (\(capped.count) bytes)")
            networkLogger.debug("chunk fetched offset=\(lower, privacy: .public) bytes=\(capped.count, privacy: .public) via curl")
            return Data(capped)
        }
        var request = URLRequest(url: upstream)
        request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        recordContentType(http.value(forHTTPHeaderField: "Content-Type"))
        if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
           let parsed = Self.parseTotal(rangeHeader), total() == nil {
            setTotal(parsed)
        }
        let capped = data.prefix(Int(Self.chunkSize))
        storeCache(chunkLower: lower, data: Data(capped))
        StreamHub.log("chunk \(lower)-\(lower + Int64(capped.count) - 1) fetched (\(capped.count) bytes)")
        networkLogger.debug("chunk fetched offset=\(lower, privacy: .public) bytes=\(capped.count, privacy: .public)")
        return Data(capped)
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
