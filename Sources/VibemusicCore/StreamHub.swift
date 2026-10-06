import Foundation
import Network
import os


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
