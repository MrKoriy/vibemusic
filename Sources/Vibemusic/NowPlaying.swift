import Foundation
import Combine
import AppKit
import SwiftUI
import MediaPlayer
import VibemusicCore

@MainActor
final class NowPlayingManager: @unchecked Sendable {
    static let shared = NowPlayingManager()

    private weak var player: PlayerCore?
    private var controller: SessionController?
    private var isActivated = false
    private var cancellables = Set<AnyCancellable>()
    private var artworkCategoryID: String?
    private var cachedArtwork: MPMediaItemArtwork?

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
        // E-11: не оставляем призрак трека после остановки/сброса — чистим центр,
        // когда трека нет либо плеер стоит вне активной сессии (idle/finished).
        // Пауза внутри work/break-фазы призраком не считается: инфо остаётся
        // с PlaybackRate 0.
        let phase = controller?.timer.phase
        let sessionInactive = phase == nil || phase == .idle || phase == .finished
        if player.current == nil || (!player.isPlaying && sessionInactive) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.current?.title ?? "Vibemusic",
            MPMediaItemPropertyArtist: player.current?.channel ?? "фокус · медитация · сон",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if player.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        if let artwork = currentArtwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func currentArtwork() -> MPMediaItemArtwork? {
        let categoryID = controller?.selectedCategoryID ?? "work"
        if categoryID == artworkCategoryID { return cachedArtwork }
        let artwork = Self.makeArtwork(categoryID: categoryID)
        artworkCategoryID = categoryID
        cachedArtwork = artwork
        return artwork
    }

    /// Обложка без сети (E-11): вертикальный градиент цвета категории
    /// (Theme.color) + крупный белый SF-символ режима (Theme.symbol), 512×512.
    /// Крэш-фикс: MPMediaItemArtwork вызывает handler на `accessQueue` (не main).
    /// Если handler замкнут на @MainActor-контекст, Swift Concurrency ловит
    /// dispatch_assert_queue / _swift_task_checkIsolated -> SIGTRAP.
    /// Поэтому рендер — на MainActor, а обёртка в MPMediaItemArtwork — nonisolated.
    private static func makeArtwork(categoryID: String) -> MPMediaItemArtwork? {
        let image = renderArtworkImage(categoryID: categoryID)
        let size = image.size
        return wrapArtwork(image: image, size: size)
    }

    private static func renderArtworkImage(categoryID: String) -> NSImage {
        let side: CGFloat = 512
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        let image = NSImage(size: bounds.size)
        let base = Theme.nsColor(for: categoryID).usingColorSpace(.sRGB) ?? .systemBlue
        let top = base.blended(withFraction: 0.30, of: .black) ?? base
        let bottom = base.blended(withFraction: 0.70, of: .black) ?? base
        guard let gradient = NSGradient(colors: [top, bottom]) else { return image }
        let symbol = NSImage(systemSymbolName: Theme.symbol(for: categoryID), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        let configured = symbol?.withSymbolConfiguration(.init(pointSize: 230, weight: .bold))
        image.lockFocus()
        gradient.draw(in: bounds, angle: -90)
        if let configured, let ctx = NSGraphicsContext.current?.cgContext {
            var symbolRect = NSRect(
                x: (side - configured.size.width) / 2,
                y: (side - configured.size.height) / 2,
                width: configured.size.width,
                height: configured.size.height
            )
            if let mask = configured.cgImage(forProposedRect: &symbolRect, context: nil, hints: nil) {
                ctx.saveGState()
                ctx.clip(to: symbolRect, mask: mask)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(symbolRect)
                ctx.restoreGState()
            }
        }
        image.unlockFocus()
        return image
    }

    nonisolated private static func wrapArtwork(image: NSImage, size: NSSize) -> MPMediaItemArtwork {
        let captured = image
        return MPMediaItemArtwork(boundsSize: size) { @Sendable _ in captured }
    }
}
