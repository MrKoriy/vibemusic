import Foundation
import AVFoundation
import Combine
import os

private final class FadeState: @unchecked Sendable {
    var steps = 16
}

/// Плеер без гонок: любое переключение (play/next/previous/stop/reset)
/// поднимает поколение воспроизведения и отменяет все висящие задачи —
/// резолвы, stall-ватчдоги, авто-переключения и fade не могут
/// «воскресить» воспроизведение или глушить новый трек (аудит A-1, A-2).
@MainActor
public final class PlayerCore: ObservableObject {
    @Published public private(set) var current: Track?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var needsRetry = false
    @Published public var statusText: String?
    @Published public var volume: Float = 0.85 {
        didSet { player.volume = volume }
    }

    /// DI-хук для тестов: резолв ссылки на поток.
    public var resolve: (String, String?) async throws -> (URL, Bool) = { videoID, proxy in
        try await YTResolver.firstSuccess(videoID: videoID, proxy: proxy)
    }

    private let logger = Logger(subsystem: "com.vibemusic.app", category: "player")
    private let player = AVPlayer()
    private var queue: [Track] = []
    private var index = 0
    private var cancellables = Set<AnyCancellable>()
    private var itemCancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var autoNextTasks: [UUID: Task<Void, Never>] = [:]
    private nonisolated(unsafe) var fadeTimer: Timer?
    private var activeStream: LocalStream?
    private var playbackGeneration = UUID()
    /// Неудачи загрузки подряд. Не даёт autoNext крутить очередь по кругу
    /// бесконечно (и каждые 1,5 с запускать yt-dlp), когда не играет ничего.
    private var consecutiveFailures = 0
    static let maxConsecutiveFailures = 5

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
                        self.consecutiveFailures = 0
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
        // Cleanup is best-effort here; authoritative cleanup is in cancelPlayback()/reset()
        // which run on MainActor. Direct player access from deinit may race — capture locally.
        let observer = timeObserver
        let timer = fadeTimer
        let avPlayer = player
        if let observer {
            // removeTimeObserver is thread-safe on AVPlayer per docs, but we dispatch
            // fadeTimer invalidation to main to avoid Timer threading issues.
            avPlayer.removeTimeObserver(observer)
        }
        if let timer {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }

    // MARK: - Публичное управление

    public func play(category: MusicCategory, shuffle: Bool) {
        guard !category.tracks.isEmpty else {
            statusText = "В этой категории нет треков"
            return
        }
        cancelPlayback()
        consecutiveFailures = 0
        queue = shuffle ? category.tracks.shuffled() : category.tracks
        index = 0
        loadCurrent()
    }

    public func next() {
        guard !queue.isEmpty else { return }
        cancelPlayback()
        index = (index + 1) % queue.count
        loadCurrent()
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        cancelPlayback()
        index = (index - 1 + queue.count) % queue.count
        loadCurrent()
    }

    /// Повторить неудавшийся трек (аудит A-7).
    public func retry() {
        guard !queue.isEmpty else { return }
        logger.info("retry запрошен")
        needsRetry = false
        consecutiveFailures = 0
        cancelPlayback()
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
        if fade, player.currentItem != nil {
            let generation = prepareFade()
            runFade(generation: generation)
        } else {
            cancelPlayback()
            player.pause()
        }
    }

    /// Полная остановка: отмена всех задач, очистка плеера и состояния.
    public func reset() {
        logger.info("reset: полная остановка")
        cancelPlayback()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        needsRetry = false
        statusText = nil
        elapsed = 0
        duration = 0
        isPlaying = false
    }

    // MARK: - Отмена и fade

    /// Единая точка отмены: поднимает поколение, снимает все висящие задачи,
    /// закрывает стрим. Любой устаревший колбэк по поколению — no-op.
    private func cancelPlayback() {
        playbackGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        stallTask?.cancel()
        stallTask = nil
        for task in autoNextTasks.values {
            task.cancel()
        }
        autoNextTasks.removeAll()
        itemCancellables.removeAll()
        if fadeTimer != nil {
            fadeTimer?.invalidate()
            fadeTimer = nil
            // Прерванный fade обязан вернуть громкость.
            player.volume = volume
        }
        if let activeStream {
            StreamHub.shared.closeStream(activeStream)
            self.activeStream = nil
        }
        isLoading = false
    }

    private func prepareFade() -> UUID {
        cancelPlayback()
        return playbackGeneration
    }

    private func runFade(generation: UUID) {
        let originalVolume = volume
        player.volume = originalVolume
        let state = FadeState()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let timer = self.fadeTimer else { return }
                // Устаревшее поколение = начато новое воспроизведение — fade молчит.
                guard generation == self.playbackGeneration else {
                    timer.invalidate()
                    return
                }
                state.steps -= 1
                if state.steps <= 0 {
                    self.player.pause()
                    self.player.volume = originalVolume
                    timer.invalidate()
                    self.fadeTimer = nil
                    self.logger.info("fade завершён, пауза")
                } else {
                    self.player.volume = originalVolume * (Float(state.steps) / 16.0)
                }
            }
        }
    }

    // MARK: - Загрузка текущего трека

    private func loadCurrent() {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        current = track
        isLoading = true
        statusText = nil
        let expectedID = track.id
        let generation = playbackGeneration
        logger.info("загрузка «\(track.title, privacy: .public)»")

        loadTask = Task { [weak self] in
            guard let self else { return }
            let resolveStart = Date()
            do {
                let proxyTool = ProxyConfig.load().toolURL
                let raced = try await self.resolve(expectedID, proxyTool)
                // Поколение сменилось (reset/next/stop) — результат неактуален.
                guard !Task.isCancelled,
                      generation == self.playbackGeneration,
                      self.current?.id == expectedID else { return }

                let item: AVPlayerItem
                if YTResolver.isManifestURL(raced.0) {
                    item = AVPlayerItem(url: raced.0)
                } else {
                    // Качка тем же маршрутом, что и резолв: googlevideo
                    // привязывает ссылку к IP запросившего.
                    let streamProxy = raced.1 ? proxyTool : nil
                    // Когда ссылка истечёт посреди многочасового трека,
                    // стрим сам получит новую тем же маршрутом.
                    let refresher: LocalStream.UpstreamRefresher = {
                        try await Task.detached(priority: .userInitiated) {
                            try YTResolver.streamURL(for: expectedID, proxy: streamProxy)
                        }.value
                    }
                    let stream = try await Task.detached(priority: .userInitiated) {
                        try StreamHub.shared.openStream(upstream: raced.0, proxy: streamProxy, refresher: refresher)
                    }.value
                    guard !Task.isCancelled,
                          generation == self.playbackGeneration,
                          self.current?.id == expectedID else {
                        StreamHub.shared.closeStream(stream)
                        return
                    }
                    self.activeStream = stream
                    item = AVPlayerItem(url: stream.localURL)
                }

                item.publisher(for: \.status)
                    .receive(on: RunLoop.main)
                    .sink { [weak self] status in
                        guard let self,
                              status == .failed,
                              generation == self.playbackGeneration,
                              self.current?.id == expectedID else { return }
                        self.logger.warning("item failed, переключение")
                        self.handleLoadFailure(trackID: expectedID, slow: false)
                    }
                    .store(in: &self.itemCancellables)

                self.player.replaceCurrentItem(with: item)
                self.player.volume = self.volume
                self.player.play()
                self.needsRetry = false
                self.prefetchSurrounding()

                self.stallTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 14_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if generation == self.playbackGeneration,
                       self.current?.id == expectedID,
                       !self.isPlaying,
                       self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        self.logger.warning("stall 14с, переключение")
                        self.statusText = "Поток не отвечает, переключаюсь…"
                        self.next()
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      generation == self.playbackGeneration else { return }
                let resolveSeconds = Date().timeIntervalSince(resolveStart)
                if let resolverError = error as? ResolverError, case .ytDlpMissing = resolverError {
                    self.statusText = resolverError.errorDescription
                } else {
                    self.handleLoadFailure(trackID: expectedID, slow: resolveSeconds > YTResolver.slowResolveThreshold)
                }
            }
            if generation == self.playbackGeneration,
               self.current?.id == expectedID {
                self.isLoading = false
            }
        }
    }

    /// Единая обработка неудачи загрузки (аудит A-7, B-9).
    private func handleLoadFailure(trackID: String, slow: Bool) {
        if slow {
            // Медленный фейл = сетевая проблема (YouTube недоступен/заторможен),
            // не гоняем autoNext по всей библиотеке.
            logger.warning("медленный фейл резолва — сеть")
            statusText = "YouTube недоступен — проверьте сеть и попробуйте ещё раз"
            needsRetry = true
            return
        }
        consecutiveFailures += 1
        // Предел: вся очередь + ещё одна попытка, но не больше maxConsecutiveFailures.
        let limit = min(Self.maxConsecutiveFailures, queue.count + 1)
        if queue.count > 1, consecutiveFailures >= limit {
            logger.warning("подряд \(self.consecutiveFailures) неудач — останавливаю autoNext")
            statusText = "Треки не загружаются — проверьте сеть и нажмите ↻"
            needsRetry = true
            return
        }
        if queue.count > 1 {
            statusText = "Не удалось загрузить «\(current?.title ?? "")»"
            needsRetry = false
            autoNext(trackID: trackID)
        } else {
            logger.warning("единственный трек недоступен — нужен retry")
            statusText = "Не удалось загрузить «\(current?.title ?? "")» — нажмите ↻"
            needsRetry = true
        }
    }

    private func autoNext(trackID: String) {
        let generation = playbackGeneration
        let id = UUID()
        autoNextTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.autoNextTasks.removeValue(forKey: id)
            guard !Task.isCancelled,
                  generation == self.playbackGeneration,
                  self.current?.id == trackID,
                  !self.isPlaying else { return }
            self.next()
        }
    }

    // MARK: - Префетч

    private func prefetchSurrounding() {
        guard !queue.isEmpty else { return }
        let nextIndex = (index + 1) % queue.count
        prefetch(track: queue[nextIndex])
    }

    public func prefetch(track: Track) {
        let fingerprint = ProxyConfig.load().fingerprint
        if StreamURLCache.shared.get(videoID: track.id, route: fingerprint) != nil { return }
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

// MARK: - Тестовые наблюдатели (используются только через @testable)

extension PlayerCore {
    var playerVolume: Float { player.volume }
    var isFadeActive: Bool { fadeTimer != nil }
    var hasCurrentItem: Bool { player.currentItem != nil }
}
