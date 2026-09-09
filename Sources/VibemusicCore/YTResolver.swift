import Foundation

public enum ResolverError: LocalizedError {
    case ytDlpMissing
    case failed(String)
    case noStream
    case nothingImported

    public var errorDescription: String? {
        switch self {
        case .ytDlpMissing:
            return "yt-dlp не найден. Установите: brew install yt-dlp"
        case .failed(let message):
            return "yt-dlp: \(message)"
        case .noStream:
            return "Не удалось получить аудиопоток. Попробуйте другой трек."
        case .nothingImported:
            return "По этой ссылке ничего не найдено."
        }
    }
}

public enum YTResolver {
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
    private nonisolated(unsafe) static var cachedPath: String?

    public static func ytDlpPath() -> String? {
        if let path = cachedPath { return path }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            cachedPath = candidate
            return candidate
        }
        return nil
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) throws -> String {
        guard let path = ytDlpPath() else { throw ResolverError.ytDlpMissing }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()]

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
        var arguments = [
            "-f", "ba[protocol^=m3u8]/234/233/bestaudio[ext=m4a]/bestaudio[ext=mp3]/bestaudio/best",
            "-g", "--no-warnings", "--no-playlist",
        ]
        if let proxy {
            arguments += ["--proxy", proxy, "--socket-timeout", "30", "--retries", "2"]
        }
        arguments.append(videoID)
        let output = try run(arguments, timeout: 50)
        guard let line = output.split(separator: "\n").first(where: { !$0.isEmpty }),
              let url = URL(string: String(line)) else {
            throw ResolverError.noStream
        }
        return url
    }

    /// Гонка: прямой резолв и через прокси параллельно, побеждает первый успешный.
    /// Маршрут важен: ссылка googlevideo привязана к IP запросившего.
    /// Дети группы блокируются на Process — это осознанно: за счёт структурной
    /// конкурентности отмена задачи завершает проигравший процесс мгновенно.
    public static func firstSuccess(videoID: String, proxy: String?) async throws -> (url: URL, viaProxy: Bool) {
        if let cached = StreamURLCache.shared.get(videoID: videoID) {
            return cached
        }
        let result = try await withThrowingTaskGroup(of: Result<(URL, Bool), Error>.self) { group in
            group.addTask {
                do {
                    return .success((try streamURL(for: videoID, proxy: nil), false))
                } catch {
                    return .failure(error)
                }
            }
            if let proxy {
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
        StreamURLCache.shared.set(videoID: videoID, url: result.0, viaProxy: result.1)
        return result
    }

    public static func importTracks(from raw: String, proxy: String? = nil) throws -> [Track] {
        let argument = normalize(raw)
        let isPlaylist = raw.contains("list=")
        var arguments: [String]
        if isPlaylist {
            arguments = ["-J", "--skip-download", "--flat-playlist", "--playlist-items", "1:50"]
        } else {
            arguments = ["-J", "--skip-download", "--no-playlist"]
        }
        if let proxy {
            arguments += ["--proxy", proxy, "--socket-timeout", "30", "--retries", "2"]
        }
        arguments.append(argument)
        let output = try run(arguments, timeout: 120)
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

    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11, trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return "https://www.youtube.com/watch?v=" + trimmed
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
