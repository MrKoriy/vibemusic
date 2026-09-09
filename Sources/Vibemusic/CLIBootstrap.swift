import Foundation
import AVFoundation
import VibemusicCore

enum CLIBootstrap {
    private static let valueFlags: Set<String> = ["--resolve", "--meta", "--verify", "--verify-url", "--proxy"]

    private struct Parsed {
        var values: [String: String] = [:]
        var present: Set<String> = []
        var positionals: [String] = []
    }

    private static func parse(_ arguments: [String]) -> Parsed {
        var parsed = Parsed()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                parsed.present.insert(argument)
                if valueFlags.contains(argument),
                   index + 1 < arguments.count,
                   !arguments[index + 1].hasPrefix("--") {
                    parsed.values[argument] = arguments[index + 1]
                    index += 2
                } else {
                    index += 1
                }
            } else {
                parsed.positionals.append(argument)
                index += 1
            }
        }
        return parsed
    }

    static func handleIfNeeded() {
        let arguments = CommandLine.arguments
        let parsed = parse(arguments)
        guard valueFlags.contains(where: parsed.present.contains) else { return }

        let proxyOverride = parsed.values["--proxy"].flatMap(ProxyConfig.toolURL(from:))

        if parsed.present.contains("--verify") {
            guard let id = parsed.values["--verify"] ?? parsed.positionals.first, !id.isEmpty else {
                FileHandle.standardError.write(Data("usage: --verify [--proxy socks5://user:pass@host:port] <videoID>\n".utf8))
                exit(2)
            }
            verifyPlayback(videoID: id, proxyOverride: proxyOverride)
        }

        if let url = parsed.values["--verify-url"], let target = URL(string: url) {
            verifyPlaybackURL(target)
        }

        let effectiveProxy = proxyOverride ?? ProxyConfig.load().toolURL

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let id = parsed.values["--resolve"] ?? parsed.positionals.first, !id.isEmpty {
                do {
                    print(try YTResolver.streamURL(for: id, proxy: effectiveProxy).absoluteString)
                } catch {
                    fail(error)
                }
            } else if let source = parsed.values["--meta"] ?? parsed.positionals.first, !source.isEmpty {
                do {
                    let tracks = try YTResolver.importTracks(from: source, proxy: effectiveProxy)
                    for track in tracks {
                        print("\(track.id) | \(track.title) | \(track.channel ?? "-") | \(track.durationLabel ?? "live")")
                    }
                } catch {
                    fail(error)
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func verifyPlayback(videoID: String, proxyOverride: String?) {
        final class VerifyState: @unchecked Sendable {
            var settled = false
            var exitCode = 4
            var stream: LocalStream?
        }
        let semaphore = DispatchSemaphore(value: 0)
        let state = VerifyState()

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

                let isManifest = url.path.hasSuffix(".m3u8") || url.path.hasSuffix(".mpd") || url.pathExtension == "m3u8" || url.absoluteString.contains(".m3u8")
                let localURL: URL
                if isManifest {
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
                            state.exitCode = 5
                            state.settled = true
                        } else if player.currentTime().seconds > 1.0 {
                            print("PLAYING_OK time=\(String(format: "%.1f", player.currentTime().seconds))")
                            state.exitCode = 0
                            state.settled = true
                        } else if elapsed > 45 {
                            print("TIMEOUT_STALLED status=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue)")
                            state.exitCode = 3
                            state.settled = true
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
                state.exitCode = 1
                semaphore.signal()
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(120))
        _ = semaphore.wait(timeout: .now().advanced(by: .seconds(5)))
        exit(Int32(state.exitCode))
    }

    /// Проверяет весь конвейер StreamHub (сервер → чанки → AVPlayer) на произвольном upstream URL.
    private static func verifyPlaybackURL(_ upstream: URL) {
        final class VerifyState: @unchecked Sendable {
            var settled = false
            var exitCode = 4
            var stream: LocalStream?
        }
        let semaphore = DispatchSemaphore(value: 0)
        let state = VerifyState()

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
                            state.exitCode = 5
                            state.settled = true
                        } else if player.currentTime().seconds > 0.5 {
                            print("PLAYING_OK time=\(String(format: "%.1f", player.currentTime().seconds))")
                            state.exitCode = 0
                            state.settled = true
                        } else if elapsed > 30 {
                            print("TIMEOUT_STALLED status=\(item.status.rawValue) control=\(player.timeControlStatus.rawValue)")
                            state.exitCode = 3
                            state.settled = true
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
                state.exitCode = 1
                semaphore.signal()
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(60))
        _ = semaphore.wait(timeout: .now().advanced(by: .seconds(5)))
        exit(Int32(state.exitCode))
    }

    private static func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
