import Foundation
import Combine
import MediaPlayer
import VibemusicCore

@MainActor
final class NowPlayingManager: @unchecked Sendable {
    static let shared = NowPlayingManager()

    private weak var player: PlayerCore?
    private var controller: SessionController?
    private var isActivated = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func activate(player: PlayerCore, controller: SessionController) {
        guard !isActivated else { return }
        isActivated = true
        self.player = player
        self.controller = controller

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { _ in
            MainActor.assumeIsolated { NowPlayingManager.shared.playPause() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { NowPlayingManager.shared.playPause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { NowPlayingManager.shared.playPause() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { NowPlayingManager.shared.skipNext() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { NowPlayingManager.shared.skipPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            MainActor.assumeIsolated { NowPlayingManager.shared.seek(to: position) }
            return .success
        }

        player.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
        player.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
        player.$elapsed
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.updateInfo() }
            .store(in: &cancellables)
    }

    private func playPause() { controller?.toggleSession() }
    private func skipNext() { player?.next() }
    private func skipPrevious() { player?.previous() }
    private func seek(to position: Double) { player?.seek(to: position) }

    private func updateInfo() {
        guard let player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.current?.title ?? "Vibemusic",
            MPMediaItemPropertyArtist: player.current?.channel ?? "фокус · медитация · сон",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if player.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
