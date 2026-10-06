import Foundation
import AVFoundation
import Combine
import os

private final class FadeState: @unchecked Sendable {
    let totalSteps: Int
    var steps: Int

    init(totalSteps: Int) {
        self.totalSteps = totalSteps
        self.steps = totalSteps
    }
}

/// Плеер без гонок: любое переключение (play/next/previous/stop/reset)
/// поднимает поколение воспроизведения и отменяет все висящие задачи —
/// резолвы, stall-ватчдоги, авто-переключения и fade не могут
/// «воскресить» воспроизведение или глушить новый трек (аудит A-1, A-2).
@MainActor
public final class PlayerCore: ObservableObject {
    /// Намерение пользователя: играть или стоять. Пауза из UI/медиа-клавиш
    /// меняет намерение, а не наблюдаемое состояние AVPlayer: новая загрузка
    /// трека (autoNext, префетч, смена) не «воскрешает» звук, пока стоит
    /// пауза, и наоборот — рассинхрона «таймер на паузе, песня играет» нет.
    public enum PlayIntent: Equatable {
        case playing
        case paused
    }

    @Published public private(set) var current: Track?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var needsRetry = false
    @Published public var statusText: String?
    @Published public var volume: Float = 0.85 {
        didSet { applyVolume() }
    }
    /// Множитель громкости поверх пользовательской (0…1): плавное затухание
    /// в конце сессии сна. Пользовательская `volume` при этом не меняется.
    @Published public private(set) var attenuation: Float = 1
    /// Громкость, которая реально уходит в AVPlayer.
    public var effectiveVolume: Float { volume * attenuation }
    @Published public private(set) var playIntent: PlayIntent = .playing

    /// DI-хук для тестов: резолв ссылки на поток.
    public var resolve: (String, String?) async throws -> (URL, Bool) = { videoID, proxy in
        try await YTResolver.firstSuccess(videoID: videoID, proxy: proxy)
    }
    /// DI-хук для тестов: кэш ссылок, который чистится при неудачах.
    public var cache: StreamURLCache = .shared

    /// Длительность fade-out по умолчанию (`stop(fade: true)`).
    public static let defaultFadeDuration: TimeInterval = 12
    static let fadeStepInterval: TimeInterval = 0.2
    /// Сколько раз подряд пытаться продолжить упавший посреди трека поток
    /// (истёкшая HLS-ссылка, обрыв сети) с той же позиции.
    nonisolated static let maxRecoveryAttempts = 2
    /// Падение раньше этой позиции считается неудачей загрузки, а не обрывом.
    nonisolated static let recoveryMinPosition: Double = 5

    private let logger = Logger(subsystem: "com.vibemusic.app", category: "player")
    /// Отладка в stderr при VIBEMUSIC_DEBUG (см. StreamHub.log).
    nonisolated static let VIBEMUSIC_DEBUG_ENABLED = ProcessInfo.processInfo.environment["VIBEMUSIC_DEBUG"] != nil
    nonisolated static func debugLog(_ message: String) {
        guard VIBEMUSIC_DEBUG_ENABLED else { return }
        let t = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
        FileHandle.standardError.write(Data(String(format: "[plr %7.2f] %@\n", t, message).utf8))
    }
    private let player = AVPlayer()
    private var queue: [Track] = []
    private var index = 0
    private var cancellables = Set<AnyCancellable>()
    private var itemCancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var autoNextTasks: [UUID: Task<Void, Never>] = [:]
    private var prewarmTasks: [Task<Void, Never>] = []
    private nonisolated(unsafe) var fadeTimer: Timer?
    private var activeStream: LocalStream?
    private var playbackGeneration = UUID()
    /// Неудачи загрузки подряд. Не даёт autoNext крутить очередь по кругу
    /// бесконечно (и каждые 1,5 с запускать yt-dlp), когда не играет ничего.
    private var consecutiveFailures = 0
    static let maxConsecutiveFailures = 5
    /// Попытки восстановления текущего трека (см. maxRecoveryAttempts).
    private var recoveryAttempts = 0
    /// Позиция последнего восстановления: защита от цикла «обрыв → резолв».
    private var lastRecoveryPosition: Double = -.infinity
    /// Треки, которые прямо сейчас резолвятся префетчем.
    private var prefetchInFlight = Set<String>()
    /// Позиция, на которую нужно перемотать после готовности нового item.
    private var pendingResumePosition: Double?

    public init() {
        player.volume = effectiveVolume
        // true: AVPlayer начинает воспроизведение, как только декодер готов,
        // но не раньше — при waits=false замена item + немедленный play()
        // в контексте NSApplication оставляли плеер в состоянии «rate=1,
        // time=0» бесконечно (аудио так и не стартует).
        // Прогрев первого чанка (prewarmStream) убирает задержку старта.
        player.automaticallyWaitsToMinimizeStalling = true

        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isPlaying = (status == .playing)
                    self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                    if PlayerCore.VIBEMUSIC_DEBUG_ENABLED {
                        let time = self.player.currentTime().seconds
                        Self.debugLog(String(
                            format: "control=%d playing=%d itemStatus=%ld rate=%.2f time=%.2f duration=%.1f",
                            status.rawValue, self.isPlaying ? 1 : 0,
                            self.player.currentItem?.status.rawValue ?? -1,
                            self.player.rate, time, self.duration
                        ))
                    }
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
                if PlayerCore.VIBEMUSIC_DEBUG_ENABLED,
                   Int(self.elapsed * 2) % 10 == 0 {
                    Self.debugLog(String(
                        format: "elapsed=%.2f duration=%.1f itemStatus=%ld",
                        self.elapsed, self.duration, self.player.currentItem?.status.rawValue ?? -1
                    ))
                }
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
        playIntent = .playing
        setAttenuation(1)
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
        // Повтор обязан идти за свежей ссылкой: в кэше могла остаться та,
        // что только что не сработала (смена сети, 403).
        if queue.indices.contains(index) {
            cache.invalidate(videoID: queue[index].id)
        }
        loadCurrent()
    }

    public func toggle() {
        if isPlaying {
            pause()
        } else {
            resumePlayback()
        }
    }

    /// Пауза по намерению: новые загрузки не запускают звук, пока она стоит.
    public func pause() {
        playIntent = .paused
        player.pause()
    }

    /// Снятие паузы по намерению.
    public func resumePlayback() {
        playIntent = .playing
        player.play()
    }

    public func seek(to seconds: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: min(max(0, seconds), duration), preferredTimescale: 600))
    }

    public func setVolume(_ value: Float) {
        volume = value
    }

    /// Множитель громкости (0…1) поверх пользовательской. Во время активного
    /// fade-out не трогаем AVPlayer: fade сам ведёт громкость к нулю.
    public func setAttenuation(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard clamped != attenuation else { return }
        attenuation = clamped
        applyVolume()
    }

    private func applyVolume() {
        guard fadeTimer == nil else { return }
        player.volume = effectiveVolume
    }

    public func stop(fade: Bool, duration: TimeInterval = PlayerCore.defaultFadeDuration) {
        if fade, player.currentItem != nil {
            let generation = prepareFade()
            runFade(generation: generation, duration: duration)
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
        isBuffering = false
        playIntent = .playing
        recoveryAttempts = 0
        setAttenuation(1)
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
        for task in prewarmTasks {
            task.cancel()
        }
        prewarmTasks.removeAll()
        itemCancellables.removeAll()
        pendingResumePosition = nil
        if fadeTimer != nil {
            fadeTimer?.invalidate()
            fadeTimer = nil
            // Прерванный fade обязан вернуть громкость.
            player.volume = effectiveVolume
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

    private func runFade(generation: UUID, duration: TimeInterval) {
        let originalVolume = effectiveVolume
        player.volume = originalVolume
        let state = FadeState(totalSteps: max(1, Int((duration / Self.fadeStepInterval).rounded())))
        // Режим .common: fade не замирает, пока открыто меню или идёт скролл.
        let timer = Timer(timeInterval: Self.fadeStepInterval, repeats: true) { [weak self] _ in
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
                    // Квадратичная кривая: на слух затухание равномернее линейного.
                    let fraction = Float(state.steps) / Float(state.totalSteps)
                    self.player.volume = originalVolume * fraction * fraction
                }
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Загрузка текущего трека

    /// Загрузка трека из очереди. `resumeAt` — восстановление после обрыва:
    /// тот же трек, свежая ссылка, перемотка на сохранённую позицию.
    private func loadCurrent(resumeAt: Double? = nil) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        if resumeAt == nil {
            recoveryAttempts = 0
            lastRecoveryPosition = -.infinity
        }
        current = track
        isLoading = true
        statusText = resumeAt == nil ? nil : "Поток оборвался, продолжаю…"
        let expectedID = track.id
        let generation = playbackGeneration
        // Live-трансляцию перематывать некуда: просто переподключаемся.
        pendingResumePosition = track.isLive ? nil : resumeAt
        logger.info("загрузка «\(track.title, privacy: .public)»\(resumeAt != nil ? " (восстановление)" : "", privacy: .public)")

        loadTask = Task { [weak self] in
            guard let self else { return }
            let resolveStart = Date()
            do {
                let proxyTool = ProxyConfig.current().toolURL
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
                        try await YTResolver.streamURL(for: expectedID, proxy: streamProxy)
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
                    if PlayerCore.VIBEMUSIC_DEBUG_ENABLED {
                        Self.debugLog("localURL=\(stream.localURL.absoluteString) upstream=\(stream.upstream.absoluteString.prefix(80))")
                    }
                    // Прогрев: общий размер и первый чанк грузятся сразу,
                    // пока AVPlayer готовит item. Первый запрос плеера
                    // попадает в тёплый кэш — звук стартует заметно быстрее.
                    let prewarm = Task { [weak stream] in
                        guard let stream else { return }
                        _ = try? await stream.ensureTotal()
                        _ = try? await stream.fetchChunk(offset: 0)
                    }
                    self.prewarmTasks.append(prewarm)
                    item = AVPlayerItem(url: stream.localURL)
                }

                item.publisher(for: \.status)
                    .receive(on: RunLoop.main)
                    .sink { [weak self] status in
                        guard let self,
                              generation == self.playbackGeneration,
                              self.current?.id == expectedID else { return }
                        switch status {
                        case .readyToPlay:
                            self.applyPendingResume(to: item)
                        case .failed:
                            self.handleItemFailure(trackID: expectedID, reason: "item failed")
                        default:
                            break
                        }
                    }
                    .store(in: &self.itemCancellables)

                // Обрыв посреди воспроизведения (истёкшие HLS-сегменты,
                // потеря сети): status при этом может остаться readyToPlay.
                NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in
                        guard let self,
                              generation == self.playbackGeneration,
                              self.current?.id == expectedID else { return }
                        self.handleItemFailure(trackID: expectedID, reason: "failed to play to end")
                    }
                    .store(in: &self.itemCancellables)

                self.player.replaceCurrentItem(with: item)
                self.player.volume = self.effectiveVolume
                Self.debugLog("item заменён (manifest=\(YTResolver.isManifestURL(raced.0)))")
                // Пауза пользователя сильнее автозапуска: трек загружен,
                // но звук включится только после resume.
                if self.playIntent == .playing {
                    self.player.play()
                }
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
                        // Ссылка не ответила — при возврате к треку резолвим заново.
                        self.cache.invalidate(videoID: expectedID)
                        self.next()
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      generation == self.playbackGeneration else { return }
                let resolveSeconds = Date().timeIntervalSince(resolveStart)
                // Ссылка могла прийти из кэша и оказаться мёртвой (openStream упал).
                self.cache.invalidate(videoID: expectedID)
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

    /// Перемотка восстановленного трека на позицию обрыва (один раз).
    private func applyPendingResume(to item: AVPlayerItem) {
        guard let position = pendingResumePosition else { return }
        pendingResumePosition = nil
        let itemDuration = item.duration.seconds
        let target = (itemDuration.isFinite && itemDuration > 0) ? min(position, max(0, itemDuration - 1)) : position
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        statusText = nil
        logger.info("восстановление: перемотка на \(target, format: .fixed(precision: 0))с")
    }

    /// Падение item. Мёртвую ссылку убираем из кэша всегда. Если трек уже
    /// играл (обрыв посреди, типично для истёкших HLS-ссылок многочасовых
    /// треков), получаем свежую ссылку и продолжаем с той же позиции, а не
    /// перескакиваем на следующий трек.
    private func handleItemFailure(trackID: String, reason: String) {
        cache.invalidate(videoID: trackID)
        let position = elapsed
        // После восстановления трек проиграл ещё минуту и больше: это новый
        // независимый обрыв, счётчик попыток начинаем заново.
        if position - lastRecoveryPosition > 60 {
            recoveryAttempts = 0
        }
        if Self.shouldRecover(position: position, attempts: recoveryAttempts) {
            recoveryAttempts += 1
            lastRecoveryPosition = position
            logger.warning("\(reason, privacy: .public) на \(position, format: .fixed(precision: 0))с, восстановление #\(self.recoveryAttempts)")
            cancelPlayback()
            loadCurrent(resumeAt: position)
            return
        }
        logger.warning("\(reason, privacy: .public), переключение")
        handleLoadFailure(trackID: trackID, slow: false)
    }

    /// Чистое правило: восстанавливаем только трек, который реально играл,
    /// и не больше maxRecoveryAttempts раз подряд.
    nonisolated static func shouldRecover(position: Double, attempts: Int) -> Bool {
        position >= recoveryMinPosition && attempts < maxRecoveryAttempts
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
        guard queue.count > 1 else { return }
        // Два следующих трека: с InnerTube-резолвом это дёшево (~1 с,
        // 1 запрос), зато переключение трека происходит мгновенно.
        let first = (index + 1) % queue.count
        let second = queue.count > 2 ? (index + 2) % queue.count : first
        prefetch(track: queue[first])
        if second != first {
            prefetch(track: queue[second])
        }
    }

    /// Фоновый резолв в кэш. Только быстрый InnerTube-путь: если он не
    /// сработал, тяжёлый yt-dlp запустится лишь при реальном воспроизведении.
    /// Один и тот же трек не резолвится параллельно дважды.
    public func prefetch(track: Track) {
        let config = ProxyConfig.current()
        if cache.get(videoID: track.id, route: config.fingerprint) != nil { return }
        guard !prefetchInFlight.contains(track.id) else { return }
        prefetchInFlight.insert(track.id)
        let videoID = track.id
        let proxyTool = config.toolURL
        Task.detached(priority: .utility) { [weak self] in
            _ = try? await YTResolver.firstSuccess(videoID: videoID, proxy: proxyTool, allowSlowFallback: false)
            await MainActor.run { [weak self] in
                _ = self?.prefetchInFlight.remove(videoID)
            }
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
    var playerRate: Float { player.rate }
}
