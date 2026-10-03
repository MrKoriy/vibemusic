import Foundation
import os

public enum ResolverError: LocalizedError {
    case ytDlpMissing
    case failed(String)
    case noStream
    case nothingImported
    case unsupportedSource

    public var errorDescription: String? {
        switch self {
        case .ytDlpMissing:
            return "yt-dlp не найден. Переустановите приложение (make install) или установите: brew install yt-dlp"
        case .failed(let message):
            return "yt-dlp: \(message)"
        case .noStream:
            return "Не удалось получить аудиопоток. Попробуйте другой трек."
        case .nothingImported:
            return "По этой ссылке ничего не найдено."
        case .unsupportedSource:
            return "Поддерживаются только ссылки YouTube (youtube.com, youtu.be) или ID видео."
        }
    }
}

public enum YTResolver {
    private static let logger = Logger(subsystem: "com.vibemusic.app", category: "network")

    /// Порог «медленного» резолва: дольше — считаем сетью, а не треком.
    public static let slowResolveThreshold: TimeInterval = 12

    /// Манифест HLS/DASH воспроизводится AVPlayer напрямую, без curl-прокачки.
    public static func isManifestURL(_ url: URL) -> Bool {
        url.path.hasSuffix(".m3u8") || url.path.hasSuffix(".mpd")
    }

    private static let candidates: [String] = {
        var paths: [String] = []
        if Bundle.main.bundlePath.hasSuffix(".app") {
            paths.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yt-dlp").path)
        }
        let projectBuildHelper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/yt-dlp").path
        paths.append(projectBuildHelper)
        paths.append(contentsOf: [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/opt/homebrew/bin/youtube-dl",
            "/usr/local/bin/youtube-dl",
        ])
        return paths
    }()
    private static let pathLock = NSLock()
    nonisolated(unsafe) private static var _cachedPath: String?

    public static func ytDlpPath() -> String? {
        pathLock.lock()
        if let path = _cachedPath {
            pathLock.unlock()
            return path
        }
        pathLock.unlock()
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            pathLock.lock()
            // Re-check after acquiring lock — another thread may have set it.
            if _cachedPath == nil { _cachedPath = candidate }
            let resolved = _cachedPath ?? candidate
            pathLock.unlock()
            return resolved
        }
        return nil
    }

    /// Содержимое конфига yt-dlp с прокси. Логин/пароль прокси не должны
    /// попадать в argv: его видит любой локальный пользователь через `ps`.
    /// yt-dlp разбирает конфиг через shlex — значение в одинарных кавычках.
    /// nil — если в URL есть перевод строки или NUL (такой URL не пропускаем).
    static func proxyConfigContents(proxy: String) -> String? {
        guard !proxy.isEmpty,
              proxy.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r\u{0}")) == nil else { return nil }
        let quoted = "'" + proxy.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "--proxy \(quoted)\n"
    }

    /// Пишет конфиг с прокси в приватную временную папку (0700/0600).
    private static func writeProxyConfig(_ proxy: String) throws -> URL {
        guard let contents = proxyConfigContents(proxy: proxy) else {
            throw ResolverError.failed("Некорректный адрес прокси")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibemusic-ytdlp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = dir.appendingPathComponent("proxy.conf")
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? FileManager.default.removeItem(at: dir)
            throw ResolverError.failed("Не удалось подготовить конфиг прокси")
        }
        return dir
    }

    private static func run(_ arguments: [String], timeout: TimeInterval, proxy: String? = nil) throws -> String {
        guard let path = ytDlpPath() else { throw ResolverError.ytDlpMissing }
        var arguments = arguments
        var proxyDir: URL?
        if let proxy {
            let dir = try writeProxyConfig(proxy)
            proxyDir = dir
            // Опции должны идти до `--`, поэтому вставляем конфиг в начало.
            arguments.insert(contentsOf: ["--config-locations", dir.appendingPathComponent("proxy.conf").path], at: 0)
        }
        defer {
            if let proxyDir { try? FileManager.default.removeItem(at: proxyDir) }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["HOME"] = NSHomeDirectory()
        task.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
        } catch {
            throw ResolverError.failed(error.localizedDescription)
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
            outDone.signal()
        }
        DispatchQueue.global().async {
            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Ожидание с проверкой отмены задачи: гонка резолвов завершает
        // проигравший процесс сразу, а не по таймауту.
        while true {
            if exited.wait(timeout: .now() + 0.25) == .success { break }
            if !task.isRunning { break }
            if Task.isCancelled {
                watchdog.cancel()
                task.terminate()
                throw CancellationError()
            }
        }
        watchdog.cancel()

        _ = outDone.wait(timeout: .now() + 5)
        _ = errDone.wait(timeout: .now() + 5)

        guard task.terminationStatus == 0 else {
            let errText = String(data: errBox.data, encoding: .utf8) ?? ""
            let lastLine = errText.split(separator: "\n").last.map(String.init) ?? ""
            let message = lastLine.isEmpty ? "exit \(task.terminationStatus)" : lastLine
            throw ResolverError.failed(String(message.prefix(180)))
        }

        return String(data: outBox.data, encoding: .utf8) ?? ""
    }

    public static func streamURL(for videoID: String, proxy: String? = nil) throws -> URL {
        // Только ID видео или ссылка YouTube: строка вида `--exec=…` не должна
        // превратиться в опцию yt-dlp (защита от подстановки аргументов).
        let target = try sanitizedSource(videoID)
        var arguments = [
            "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio[ext=mp3]/bestaudio[protocol^=m3u8]",
            "-g", "--no-warnings", "--no-playlist",
        ]
        if proxy != nil {
            // Сам прокси передаётся через --config-locations (см. run), не в argv.
            arguments += ["--socket-timeout", "30", "--retries", "2"]
        }
        // `--` — конец опций: дальше yt-dlp трактует аргумент только как URL/ID.
        arguments += ["--", target]
        let output = try run(arguments, timeout: 50, proxy: proxy)
        guard let line = output.split(separator: "\n").first(where: { !$0.isEmpty }),
              let url = URL(string: String(line)) else {
            throw ResolverError.noStream
        }
        return url
    }

    /// Резолв ссылки с учётом режима прокси из ProxyConfig:
    /// forced — только прокси-ветка (прямой yt-dlp не запускаем),
    /// direct — только прямая, auto — гонка, побеждает первый успешный.
    /// Маршрут важен: ссылка googlevideo привязана к IP запросившего, поэтому
    /// кэш сверяется по отпечатку текущего прокси и пишется вместе с ним.
    /// Дети группы блокируются на Process — это осознанно: за счёт структурной
    /// конкурентности отмена задачи завершает проигравший процесс мгновенно.
    public static func firstSuccess(videoID: String, proxy: String?) async throws -> (url: URL, viaProxy: Bool) {
        let config = ProxyConfig.load()
        let started = Date()

        if config.mode == .forced, proxy == nil {
            logger.error("resolve id=\(videoID, privacy: .public) route=forced failed: proxy not configured")
            throw ResolverError.failed("Режим «только через прокси» включён, но прокси не настроен")
        }

        // Отпечаток фактического маршрута: direct — без прокси, иначе — прокси из параметра.
        let routeFingerprint: String? = config.mode == .direct
            ? nil
            : proxy.flatMap(ProxyConfig.fingerprint(ofToolURL:))

        if let cached = StreamURLCache.shared.get(videoID: videoID, route: routeFingerprint) {
            // В forced-режиме прямые записи не переиспользуем даже при совпадении отпечатка.
            if config.mode != .forced || cached.viaProxy {
                logger.log("resolve id=\(videoID, privacy: .public) route=cache hit")
                return cached
            }
        }

        let raceDirect: Bool
        let raceProxy: Bool
        switch config.mode {
        case .direct:
            raceDirect = true
            raceProxy = false
        case .forced:
            raceDirect = false
            raceProxy = true
        case .auto:
            raceDirect = true
            raceProxy = proxy != nil
        }

        do {
            let result = try await withThrowingTaskGroup(of: Result<(URL, Bool), Error>.self) { group in
                if raceDirect {
                    group.addTask {
                        do {
                            return .success((try streamURL(for: videoID, proxy: nil), false))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                if raceProxy, let proxy {
                    group.addTask {
                        do {
                            return .success((try streamURL(for: videoID, proxy: proxy), true))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var lastError: Error?
                for try await result in group {
                    if case .success(let value) = result {
                        group.cancelAll()
                        return value
                    }
                    if case .failure(let error) = result {
                        lastError = error
                    }
                }
                throw lastError ?? ResolverError.noStream
            }
            StreamURLCache.shared.set(
                videoID: videoID,
                url: result.0,
                viaProxy: result.1,
                fingerprint: routeFingerprint
            )
            logger.log(
                "resolve id=\(videoID, privacy: .public) route=\(result.1 ? "proxy" : "direct", privacy: .public) seconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)"
            )
            return result
        } catch {
            if !Task.isCancelled {
                logger.error(
                    "resolve id=\(videoID, privacy: .public) route=\(config.mode.rawValue, privacy: .public) failed seconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)"
                )
            }
            throw error
        }
    }

    public static func importTracks(from raw: String, proxy: String? = nil, playlist: Bool? = nil) throws -> [Track] {
        let argument = try sanitizedSource(raw)
        let isPlaylist = playlist ?? raw.contains("list=")
        var arguments: [String]
        if isPlaylist {
            arguments = ["-J", "--skip-download", "--flat-playlist", "--playlist-items", "1:50"]
        } else {
            arguments = ["-J", "--skip-download", "--no-playlist"]
        }
        if proxy != nil {
            // Сам прокси передаётся через --config-locations (см. run), не в argv.
            arguments += ["--socket-timeout", "30", "--retries", "2"]
        }
        arguments += ["--", argument]
        let output = try run(arguments, timeout: 120, proxy: proxy)
        guard let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ResolverError.nothingImported
        }

        if json["_type"] as? String == "playlist",
           let entries = json["entries"] as? [[String: Any]] {
            let tracks = entries.compactMap { entry -> Track? in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                let title = (entry["title"] as? String) ?? "Без названия"
                let channel = (entry["channel"] as? String) ?? (entry["uploader"] as? String)
                let duration = entry["duration"] as? Double
                return Track(id: id, title: title, channel: channel, duration: duration)
            }
            guard !tracks.isEmpty else { throw ResolverError.nothingImported }
            return tracks
        }

        guard let id = json["id"] as? String, !id.isEmpty else { throw ResolverError.nothingImported }
        let title = (json["title"] as? String) ?? "Без названия"
        let channel = (json["channel"] as? String) ?? (json["uploader"] as? String)
        let duration = json["duration"] as? Double
        return [Track(id: id, title: title, channel: channel, duration: duration)]
    }

    /// Хосты, ссылки с которых разрешено передавать в yt-dlp.
    static let allowedHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtube-nocookie.com", "youtube-nocookie.com",
    ]

    static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }

    /// Приводит пользовательский ввод к безопасному аргументу yt-dlp:
    /// ID видео → полная ссылка; https-ссылка YouTube → как есть; иначе — ошибка.
    /// Ничто, начинающееся с «-», сюда не проходит.
    static func sanitizedSource(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVideoID(trimmed) {
            return "https://www.youtube.com/watch?v=" + trimmed
        }
        guard !trimmed.hasPrefix("-"),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host) else {
            throw ResolverError.unsupportedSource
        }
        return trimmed
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var data: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
