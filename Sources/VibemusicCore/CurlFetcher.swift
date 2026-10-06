import Foundation
import os

/// Общий логгер сетевого слоя (curl, локальный стрим-сервер).
let networkLogger = Logger(subsystem: "com.vibemusic.app", category: "network")

/// Ограничивает число одновременно запущенных внешних процессов (curl, yt-dlp). Актор вместо
/// DispatchSemaphore: ожидание слота не блокирует потоки кооперативного пула.
actor ProcessSlotLimiter {
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

    /// Метод запроса: GET (по умолчанию) или POST с телом из файла.
    /// Тело пишется во временный файл — креды прокси и большие тела
    /// не попадают в argv процесса.
    enum Method {
        case get
        case post(body: Data, contentType: String)
    }

    static let maxConcurrentProcesses = 4
    private static let limiter = ProcessSlotLimiter(limit: maxConcurrentProcesses)
    private static let watchdogQueue = DispatchQueue(label: "vibemusic.curl.watchdog")

    /// Асинхронная загрузка: максимум `maxConcurrentProcesses` параллельных
    /// curl-процессов, кооперативная отмена задачи завершает процесс.
    static func fetch(
        url: URL,
        method: Method = .get,
        headers: [String: String] = [:],
        range: (start: Int64, end: Int64)? = nil,
        proxy: String? = nil,
        timeout: TimeInterval
    ) async throws -> Response {
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let response = try await runCurlProcess(
                url: url,
                method: method,
                headers: headers,
                range: range,
                proxy: proxy,
                timeout: timeout
            )
            await limiter.release()
            return response
        } catch {
            await limiter.release()
            throw error
        }
    }

    private static func runCurlProcess(
        url: URL,
        method: Method,
        headers: [String: String],
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
        // Заголовки запроса: не секреты (UA, visitor id), но экранируем кавычки.
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            let safeKey = key.replacingOccurrences(of: "\"", with: "")
            let safeValue = value.replacingOccurrences(of: "\"", with: "\\\"")
            arguments += ["-H", "\(safeKey): \(safeValue)"]
        }
        switch method {
        case .get:
            break
        case .post(let body, let contentType):
            let bodyPathFile = workDir.appendingPathComponent("request-body").path
            try body.write(to: URL(fileURLWithPath: bodyPathFile))
            let safeContentType = contentType.replacingOccurrences(of: "\"", with: "")
            arguments += ["-X", "POST", "-H", "Content-Type: \(safeContentType)", "--data-binary", "@\(bodyPathFile)"]
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
