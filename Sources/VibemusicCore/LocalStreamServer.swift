import Foundation
import Network

/// Загрузка через системный curl. Нужна, потому что URLSession не умеет
/// SOCKS5 с авторизацией, а AVPlayer-совместимый стриминг идёт через
/// Range-запросы к googlevideo.
enum CurlFetcher {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static func fetch(
        url: URL,
        range: (start: Int64, end: Int64)? = nil,
        proxy: String? = nil,
        timeout: TimeInterval
    ) throws -> Response {
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

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = arguments
        let stderrPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = stderrPipe
        try task.run()

        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 10, execute: watchdog)
        task.waitUntilExit()
        watchdog.cancel()

        let body = (try? Data(contentsOf: URL(fileURLWithPath: bodyPath))) ?? Data()
        let headerDump = (try? String(contentsOf: URL(fileURLWithPath: headerPath), encoding: .utf8)) ?? ""

        guard task.terminationStatus == 0 else {
            throw mapError(exitCode: task.terminationStatus)
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
        return stream
    }

    public func closeStream(_ stream: LocalStream) {
        streamsLock.lock()
        streams.removeValue(forKey: stream.token)
        streamsLock.unlock()
        stream.close()
    }

    func stream(for token: String) -> LocalStream? {
        streamsLock.lock()
        defer { streamsLock.unlock() }
        return streams[token]
    }

    private func accept(_ connection: NWConnection) {
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
            var loopback = false
            switch host {
            case .ipv4(let address): loopback = address == .loopback
            case .ipv6(let address): loopback = address == .loopback
            default: loopback = false
            }
            guard loopback else {
                connection.cancel()
                return
            }
        }
        HTTPConnectionHandler(connection: connection, hub: self).run()
    }
}

public final class LocalStream: @unchecked Sendable {
    public let token = UUID().uuidString
    public let upstream: URL
    public let localURL: URL

    static let chunkSize: Int64 = 1_048_576
    static let maxCacheBytes = 48 * 1_048_576
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private let session: URLSession
    private let proxyURL: String?
    private let lock = NSLock()
    private var cache: [Int64: Data] = [:]
    private var cacheBytes = 0
    private var totalLength: Int64?
    private var inflight: [Int64: ChunkTask] = [:]
    private var closed = false

    private final class ChunkTask {
        let id = UUID()
        let task: Task<Data, Error>
        init(task: Task<Data, Error>) { self.task = task }
    }

    init(upstream: URL, port: UInt16, proxyURL: String? = nil) {
        self.upstream = upstream
        self.proxyURL = proxyURL
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

    private func cachedData(forChunk lower: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : cache[lower]
    }

    private func storeCache(chunkLower: Int64, data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if cache[chunkLower] == nil {
            cacheBytes += data.count
        }
        cache[chunkLower] = data
        while cacheBytes > Self.maxCacheBytes, let smallest = cache.keys.min() {
            if let removed = cache.removeValue(forKey: smallest) {
                cacheBytes -= removed.count
            }
        }
        lock.unlock()
    }

    // MARK: - Загрузка чанков

    func ensureTotal() async throws -> Int64 {
        if let known = total() { return known }
        if let proxyURL {
            let response = try await Task.detached(priority: .userInitiated) { [upstream] in
                try CurlFetcher.fetch(url: upstream, range: (0, 1), proxy: proxyURL, timeout: 20)
            }.value
            guard (200...299).contains(response.status) else {
                throw URLError(.badServerResponse)
            }
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
            let upstream = self.upstream
            let response = try await Task.detached(priority: .userInitiated) {
                try CurlFetcher.fetch(
                    url: upstream,
                    range: (lower, upper),
                    proxy: proxyURL,
                    timeout: 45
                )
            }.value
            guard (200...299).contains(response.status), !response.body.isEmpty else {
                throw URLError(.badServerResponse)
            }
            if let rangeHeader = response.headers["content-range"],
               let parsed = Self.parseTotal(rangeHeader), total() == nil {
                setTotal(parsed)
            }
            let capped = response.body.prefix(Int(Self.chunkSize))
            storeCache(chunkLower: lower, data: Data(capped))
            StreamHub.log("chunk \(lower)-\(lower + Int64(capped.count) - 1) via curl (\(capped.count) bytes)")
            return Data(capped)
        }
        var request = URLRequest(url: upstream)
        request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
           let parsed = Self.parseTotal(rangeHeader), total() == nil {
            setTotal(parsed)
        }
        let capped = data.prefix(Int(Self.chunkSize))
        storeCache(chunkLower: lower, data: Data(capped))
        StreamHub.log("chunk \(lower)-\(lower + Int64(capped.count) - 1) fetched (\(capped.count) bytes)")
        return Data(capped)
    }
}

// MARK: - HTTP

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

        pumpTask = Task {
            await self.serve(stream: stream, range: range)
        }
    }

    static func parseRange(_ value: String) -> (start: Int64, end: Int64?)? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)
        let end = endText.isEmpty ? nil : Int64(endText)
        return (start, end)
    }

    private func serve(stream: LocalStream, range: (start: Int64, end: Int64?)?) async {
        do {
            let total = try await stream.ensureTotal()
            guard total > 0 else {
                respondSimple(status: "404 Not Found")
                return
            }

            let start = range?.start ?? 0
            var end = range?.end ?? (total - 1)
            end = min(end, total - 1)
            guard start >= 0, start <= end else {
                respond416(total: total)
                return
            }

            let length = end - start + 1
            var head = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\n"
            head += "Content-Type: audio/mp4\r\n"
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
