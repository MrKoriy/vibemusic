import Foundation
import AVFoundation
import VibemusicCore

enum CLIBootstrap {
    // MARK: - Парсинг аргументов (чистая функция, покрыта CLITests)

    struct CLIOptions: Equatable, Sendable {
        enum Verb: Equatable, Sendable {
            case verify(videoID: String)
            case verifyURL(url: String)
            case resolve(target: String)
            case meta(source: String)
        }

        var verb: Verb?
        var proxy: String?
    }

    enum ParseOutcome: Equatable, Sendable {
        /// Обычный запуск приложения без CLI-флагов.
        case launchApp
        /// Запустить CLI-режим с разобранными опциями.
        case run(CLIOptions)
        /// Ошибка использования: usage в stderr + exit 2.
        case invalid(String)
    }

    static let usage = """
    usage: Vibemusic [--verify <videoID> | --verify-url <URL> | --resolve <ID|URL> | --meta <URL>] [--proxy <socks5://user:pass@host:port>]

    Флаги:
      --verify <videoID>     проверить воспроизведение: резолв → стрим → AVPlayer
      --verify-url <URL>     проверить конвейер StreamHub на произвольном upstream URL
      --resolve <ID|URL>     вывести прямую ссылку на аудиопоток
      --meta <URL|ID>        вывести метаданные трека или плейлиста
      --proxy <socks5://…>   прокси только для этого запуска (иначе — из настроек)

    Коды выхода:
      0  успех
      1  ошибка резолва или открытия потока
      2  неверные аргументы (этот usage)
      3  таймаут стрима: воспроизведение не началось
      5  ошибка элемента плеера (AVPlayerItem failed)
    """

    private static let verbFlagsByPriority = ["--verify", "--verify-url", "--resolve", "--meta"]

    static func parse(_ arguments: [String]) -> ParseOutcome {
        var verbValues: [String: String] = [:]
        var proxy: String?
        var positionals: [String] = []
        var sawFlag = false
        let knownFlags = Set(verbFlagsByPriority).union(["--proxy"])

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }
            sawFlag = true
            guard knownFlags.contains(argument) else {
                return .invalid("неизвестный флаг: \(argument)")
            }
            let value: String?
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                value = arguments[index + 1]
                index += 2
            } else {
                value = nil
                index += 1
            }
            if argument == "--proxy" {
                guard let value, !value.isEmpty else {
                    return .invalid("--proxy требует значение: socks5://user:pass@host:port")
                }
                proxy = value
            } else {
                verbValues[argument] = value ?? ""
            }
        }

        guard sawFlag else { return .launchApp }

        if proxy != nil && verbValues.isEmpty {
            return .invalid("--proxy используется только вместе с --verify, --resolve, --meta или --verify-url")
        }

        var options = CLIOptions(verb: nil, proxy: proxy)
        for flag in verbFlagsByPriority {
            guard let raw = verbValues[flag] else { continue }
            let value = raw.isEmpty ? (positionals.first ?? "") : raw
            guard !value.isEmpty else {
                return .invalid("\(flag) требует значение")
            }
            options.verb = makeVerb(flag: flag, value: value)
            break
        }
        return .run(options)
    }

    private static func makeVerb(flag: String, value: String) -> CLIOptions.Verb? {
        switch flag {
        case "--verify": return .verify(videoID: value)
        case "--verify-url": return .verifyURL(url: value)
        case "--resolve": return .resolve(target: value)
        case "--meta": return .meta(source: value)
        default: return nil
        }
    }

    // MARK: - Входная точка

    static func handleIfNeeded() {
        switch parse(CommandLine.arguments) {
        case .launchApp:
            return
        case .invalid(let message):
            FileHandle.standardError.write(Data((message + "\n" + usage + "\n").utf8))
            exit(2)
        case .run(let options):
            let proxyOverride = options.proxy.flatMap(ProxyConfig.toolURL(from:))
            switch options.verb {
            case .verify(let videoID):
                verifyPlayback(videoID: videoID, proxyOverride: proxyOverride)
            case .verifyURL(let raw):
                guard let target = URL(string: raw) else {
                    FileHandle.standardError.write(Data("некорректный URL: \(raw)\n".utf8))
                    exit(2)
                }
                verifyPlaybackURL(target)
            case .resolve(let target):
                runDetached(proxyOverride: proxyOverride) { proxy in
                    do {
                        print(try YTResolver.streamURL(for: target, proxy: proxy).absoluteString)
                    } catch {
                        fail(error)
                    }
                }
            case .meta(let source):
                runDetached(proxyOverride: proxyOverride) { proxy in
                    do {
                        let tracks = try YTResolver.importTracks(from: source, proxy: proxy)
                        for track in tracks {
                            print("\(track.id) | \(track.title) | \(track.channel ?? "-") | \(track.durationLabel ?? "live")")
                        }
                    } catch {
                        fail(error)
                    }
                }
            case nil:
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                exit(2)
            }
        }
    }

    /// Одиночная detached-команда без таймеров: блокирует поток до завершения.
    private static func runDetached(proxyOverride: String?, _ body: @escaping @Sendable (String?) -> Void) {
        let effectiveProxy = proxyOverride ?? ProxyConfig.load().toolURL
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            body(effectiveProxy)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    // MARK: - Верификация воспроизведения

    /// Общее состояние верификации: атомарные код/флаг завершения.
    private final class VerifyState: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32 = 4
        private var done = false

        var settled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done
        }

        var exitCode: Int32 {
            lock.lock()
            defer { lock.unlock() }
            return code
        }

        func finish(_ code: Int32) {
            lock.lock()
            self.code = code
            done = true
            lock.unlock()
        }

        var stream: LocalStream?
    }

    /// Прерываемое ожидание (D-1): основной поток крутит run loop
    /// секундными слайсами и проверяет settled, а не блокируется на весь
    /// таймаут — успешный --verify завершается в пределах секунды после
    /// PLAYING_OK. Keepalive-таймер не даёт run loop выйти мгновенно в фазе
    /// резолва, когда источники ещё не зарегистрированы.
    private static func waitInterruptibly(state: VerifyState, timeout: TimeInterval) {
        let keepAlive = Timer(timeInterval: 0.25, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }

        let deadline = Date().addingTimeInterval(timeout)
        while !state.settled && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }

    private static func verifyPlayback(videoID: String, proxyOverride: String?) {
        let state = VerifyState()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            let effectiveProxy = proxyOverride ?? ProxyConfig.load().toolURL
            let resolveStart = Date()
            do {
                let url: URL
                let viaProxy: Bool
                if let proxyOverride {
                    // Явный --proxy: проверяем именно этот маршрут.
                    url = try YTResolver.streamURL(for: videoID, proxy: proxyOverride)
                    viaProxy = true
                    print("RESOLVED_IN \(String(format: "%.1f", Date().timeIntervalSince(resolveStart)))s [proxy]")
                } else {
                    // Как в приложении: гонка прямой vs прокси из настроек.
                    let raced = try await YTResolver.firstSuccess(videoID: videoID, proxy: ProxyConfig.load().toolURL)
                    url = raced.url
                    viaProxy = raced.viaProxy
                    print("RESOLVED_IN \(String(format: "%.1f", Date().timeIntervalSince(resolveStart)))s [\(viaProxy ? "proxy" : "direct")]")
                }

                // Манифест HLS/DASH AVPlayer играет напрямую, без curl-прокачки.
                let localURL: URL
                if YTResolver.isManifestURL(url) {
                    localURL = url
                } else {
                    let stream = try StreamHub.shared.openStream(upstream: url, proxy: viaProxy ? effectiveProxy : nil)
                    state.stream = stream
                    localURL = stream.localURL
                }

                DispatchQueue.main.async {
                    let item = AVPlayerItem(url: localURL)
                    let player = AVPlayer(playerItem: item)
                    player.volume = 0
                    player.automaticallyWaitsToMinimizeStalling = true
                    player.play()

                    let start = Date()
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                        let elapsed = Date().timeIntervalSince(start)
                        if item.status == .failed {
                            print("ITEM_ERROR: \(item.error.map(String.init(describing:)) ?? "nil")")
                            state.finish(5)
                        } else if player.currentTime().seconds > 1.0 {
                            print("PLAYING_OK time=\(String(format: "%.1f", player.currentTime().seconds))")
                            state.finish(0)
                        } else if elapsed > 45 {
                            print("TIMEOUT_STALLED status=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue)")
                            state.finish(3)
                        }
                        if state.settled {
                            timer.invalidate()
                            player.pause()
                            if let stream = state.stream {
                                StreamHub.shared.closeStream(stream)
                            }
                            semaphore.signal()
                        }
                    }
                }
            } catch {
                print("RESOLVE_ERROR: \(error.localizedDescription)")
                state.finish(1)
                semaphore.signal()
            }
        }

        waitInterruptibly(state: state, timeout: 120)
        _ = semaphore.wait(timeout: .now().advanced(by: .seconds(5)))
        exit(Int32(state.exitCode))
    }

    /// Проверяет весь конвейер StreamHub (сервер → чанки → AVPlayer) на произвольном upstream URL.
    private static func verifyPlaybackURL(_ upstream: URL) {
        let state = VerifyState()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            do {
                let stream = try StreamHub.shared.openStream(upstream: upstream)
                state.stream = stream
                print("LOCAL_URL: \(stream.localURL.absoluteString)", terminator: "")
                _ = stream.localURL
                fflush(stdout)
                DispatchQueue.main.async {
                    let item = AVPlayerItem(url: stream.localURL)
                    let player = AVPlayer(playerItem: item)
                    player.volume = 0
                    player.automaticallyWaitsToMinimizeStalling = true
                    player.play()

                    let start = Date()
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                        let elapsed = Date().timeIntervalSince(start)
                        if item.status == .failed {
                            print("ITEM_ERROR: \(item.error.map(String.init(describing:)) ?? "nil")")
                            state.finish(5)
                        } else if player.currentTime().seconds > 0.5 {
                            print("PLAYING_OK time=\(String(format: "%.1f", player.currentTime().seconds))")
                            state.finish(0)
                        } else if elapsed > 30 {
                            print("TIMEOUT_STALLED status=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue)")
                            state.finish(3)
                        }
                        if state.settled {
                            timer.invalidate()
                            player.pause()
                            if let stream = state.stream {
                                StreamHub.shared.closeStream(stream)
                            }
                            semaphore.signal()
                        }
                    }
                }
            } catch {
                print("OPEN_ERROR: \(error.localizedDescription)")
                state.finish(1)
                semaphore.signal()
            }
        }

        waitInterruptibly(state: state, timeout: 60)
        _ = semaphore.wait(timeout: .now().advanced(by: .seconds(5)))
        exit(Int32(state.exitCode))
    }

    private static func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
