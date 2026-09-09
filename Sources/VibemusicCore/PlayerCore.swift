import Foundation
import AVFoundation
import Combine

private final class FadeState: @unchecked Sendable {
    var steps = 16
}

@MainActor
public final class PlayerCore: ObservableObject {
    @Published public private(set) var current: Track?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public var statusText: String?
    @Published public var volume: Float = 0.85 {
        didSet { player.volume = volume }
    }

    private let player = AVPlayer()
    private var queue: [Track] = []
    private var index = 0
    private var cancellables = Set<AnyCancellable>()
    private var itemCancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private nonisolated(unsafe) var fadeTimer: Timer?
    private var activeStream: LocalStream?

    public init() {
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = true

        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isPlaying = (status == .playing)
                    if self.isPlaying {
                        self.stallTask?.cancel()
                        self.stallTask = nil
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard let item = note.object as? AVPlayerItem,
                          item === self.player.currentItem else { return }
                    self.next()
                }
            }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
            queue: DispatchQueue.main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.elapsed = max(0, time.seconds)
                let d = self.player.currentItem?.duration.seconds ?? 0
                self.duration = (d.isFinite && d > 0) ? d : 0
            }
        }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        fadeTimer?.invalidate()
    }

    public func play(category: MusicCategory, shuffle: Bool) {
        guard !category.tracks.isEmpty else {
            statusText = "В этой категории нет треков"
            return
        }
        queue = shuffle ? category.tracks.shuffled() : category.tracks
        index = 0
        loadCurrent()
    }

    public func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        loadCurrent()
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        index = (index - 1 + queue.count) % queue.count
        loadCurrent()
    }

    public func toggle() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    public func seek(to seconds: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: min(max(0, seconds), duration), preferredTimescale: 600))
    }

    public func setVolume(_ value: Float) {
        volume = value
    }

    public func stop(fade: Bool) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard fade else {
            player.pause()
            return
        }
        let originalVolume = volume
        let state = FadeState()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let timer = self.fadeTimer else { return }
                state.steps -= 1
                if state.steps <= 0 {
                    self.player.pause()
                    self.player.volume = originalVolume
                    timer.invalidate()
                    self.fadeTimer = nil
                } else {
                    self.player.volume = originalVolume * (Float(state.steps) / 16.0)
                }
            }
        }
    }

    private func loadCurrent() {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        current = track
        isLoading = true
        statusText = nil
        let expectedID = track.id
        loadTask?.cancel()
        stallTask?.cancel()
        itemCancellables.removeAll()
        if let oldStream = activeStream {
            StreamHub.shared.closeStream(oldStream)
            activeStream = nil
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let resolveStart = Date()
            do {
                let proxyTool = ProxyConfig.load().toolURL
                let raced = try await YTResolver.firstSuccess(videoID: expectedID, proxy: proxyTool)
                let url = raced.url
                guard !Task.isCancelled, self.current?.id == expectedID else { return }

                let isManifest = url.path.hasSuffix(".m3u8") || url.path.hasSuffix(".mpd") || url.pathExtension == "m3u8" || url.absoluteString.contains(".m3u8")
                let item: AVPlayerItem
                if isManifest {
                    item = AVPlayerItem(url: url)
                } else {
                    // Качка тем же маршрутом, что и резолв: googlevideo
                    // привязывает ссылку к IP запросившего.
                    let streamProxy = raced.viaProxy ? proxyTool : nil
                    let stream = try await Task.detached(priority: .userInitiated) {
                        try StreamHub.shared.openStream(upstream: url, proxy: streamProxy)
                    }.value
                    guard !Task.isCancelled, self.current?.id == expectedID else {
                        StreamHub.shared.closeStream(stream)
                        return
                    }
                    self.activeStream = stream
                    item = AVPlayerItem(url: stream.localURL)
                }

                item.publisher(for: \.status)
                    .receive(on: RunLoop.main)
                    .sink { [weak self] status in
                        guard let self, status == .failed, self.current?.id == expectedID else { return }
                        self.statusText = "Трек недоступен, переключаюсь…"
                        self.autoNext(trackID: expectedID)
                    }
                    .store(in: &self.itemCancellables)

                self.player.replaceCurrentItem(with: item)
                self.player.volume = self.volume
                self.player.play()
                self.prefetchSurrounding()

                self.stallTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 14_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if self.current?.id == expectedID,
                       !self.isPlaying,
                       self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        self.statusText = "Поток не отвечает, переключаюсь…"
                        self.next()
                    }
                }
            } catch {
                if Task.isCancelled { return }
                let resolveSeconds = Date().timeIntervalSince(resolveStart)
                if let resolverError = error as? ResolverError, case .ytDlpMissing = resolverError {
                    self.statusText = resolverError.errorDescription
                } else if resolveSeconds > 12 {
                    // Медленный фейл = сетевая проблема (YouTube недоступен/заторможен),
                    // не гоняем autoNext по всей библиотеке.
                    self.statusText = "YouTube недоступен — проверьте сеть и попробуйте ещё раз"
                } else {
                    self.statusText = "Не удалось загрузить «\(track.title)»"
                    self.autoNext(trackID: expectedID)
                }
            }
            if self.current?.id == expectedID {
                self.isLoading = false
            }
        }
    }

    private func autoNext(trackID: String) {
        guard queue.count > 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.current?.id == trackID, !self.isPlaying else { return }
            self.next()
        }
    }

    private func prefetchSurrounding() {
        guard !queue.isEmpty else { return }
        let nextIndex = (index + 1) % queue.count
        let nextTrack = queue[nextIndex]
        prefetch(track: nextTrack)
    }

    public func prefetch(track: Track) {
        if StreamURLCache.shared.get(videoID: track.id) != nil { return }
        Task.detached(priority: .utility) {
            let proxyTool = ProxyConfig.load().toolURL
            _ = try? await YTResolver.firstSuccess(videoID: track.id, proxy: proxyTool)
        }
    }

    public func warmup(category: MusicCategory) {
        guard let first = category.tracks.first else { return }
        prefetch(track: first)
    }
}
