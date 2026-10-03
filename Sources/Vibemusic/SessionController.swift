import Foundation
import Combine
import AppKit
import VibemusicCore

@MainActor
final class SessionController: ObservableObject {
    let player: PlayerCore
    let timer: TimerEngine
    let store: LibraryStore
    let stats: StatsStore

    @Published private(set) var selectedCategoryID: String?
    @Published private(set) var isWaitingForStream = false
    @Published var shuffle: Bool { didSet { defaults.set(shuffle, forKey: AppDefaults.Keys.shuffle) } }
    @Published var volume: Float { didSet { player.setVolume(volume); defaults.set(volume, forKey: AppDefaults.Keys.volume) } }
    @Published var sessionMinutes: Int { didSet { defaults.set(sessionMinutes, forKey: AppDefaults.Keys.sessionMinutes) } }
    @Published var timerModeRaw: String { didSet { defaults.set(timerModeRaw, forKey: AppDefaults.Keys.timerMode) } }
    @Published var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: AppDefaults.Keys.breakMinutes) } }

    var timerMode: TimerEngine.Mode { TimerEngine.Mode(rawValue: timerModeRaw) ?? .countdown }

    private struct PendingStart {
        let minutes: Int
        let mode: TimerEngine.Mode
        let breakMinutes: Int
        let sessionMode: SessionMode
    }

    private var pending: PendingStart?
    private var activeSessionMode: SessionMode?
    private var fallbackTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let defaults: UserDefaults

    init(store: LibraryStore, player: PlayerCore, timer: TimerEngine, stats: StatsStore,
         defaults: UserDefaults = .standard, warmupEnabled: Bool = true) {
        self.store = store
        self.player = player
        self.timer = timer
        self.stats = stats
        self.defaults = defaults

        shuffle = AppDefaults.migratedValue(defaults, newKey: AppDefaults.Keys.shuffle, legacyKey: AppDefaults.Keys.Legacy.shuffle, fallback: AppDefaults.shuffle)
        volume = AppDefaults.migratedValue(defaults, newKey: AppDefaults.Keys.volume, legacyKey: AppDefaults.Keys.Legacy.volume, fallback: AppDefaults.volume)
        sessionMinutes = AppDefaults.migratedValue(defaults, newKey: AppDefaults.Keys.sessionMinutes, legacyKey: AppDefaults.Keys.Legacy.sessionMinutes, fallback: AppDefaults.sessionMinutes)
        timerModeRaw = AppDefaults.migratedValue(defaults, newKey: AppDefaults.Keys.timerMode, legacyKey: AppDefaults.Keys.Legacy.timerMode, fallback: AppDefaults.timerModeRaw)
        breakMinutes = AppDefaults.migratedValue(defaults, newKey: AppDefaults.Keys.breakMinutes, legacyKey: AppDefaults.Keys.Legacy.breakMinutes, fallback: AppDefaults.breakMinutes)

        timer.bell = {
            if let sound = NSSound(named: "Glass") ?? NSSound(named: "Ping") {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
        timer.onSessionEnd = { [weak self] in
            self?.player.stop(fade: true)
        }
        timer.onWorkPhaseCompleted = { [weak self] minutes in
            guard let self, minutes > 0 else { return }
            self.stats.record(minutes: minutes, mode: self.sessionModeForStats)
        }

        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                if playing { self?.beginTimerWhenReady() }
            }
            .store(in: &cancellables)

        player.setVolume(volume)
        if warmupEnabled, let firstCat = store.category(id: "work") ?? store.curated.first {
            player.warmup(category: firstCat)
        }
    }

    var selectedCategory: MusicCategory? {
        selectedCategoryID.flatMap { store.category(id: $0) }
    }

    /// Режим для статистики: категория, в которой сессия была СТАРТОВАНА
    /// (аудит A-6), а не текущая выбранная.
    private var sessionModeForStats: SessionMode {
        activeSessionMode ?? selectedCategory?.mode ?? .focus
    }

    func select(_ category: MusicCategory) {
        if selectedCategoryID == category.id {
            player.next()
            return
        }
        startSession(category)
    }

    func startSession(_ category: MusicCategory) {
        guard !category.tracks.isEmpty else { return }
        selectedCategoryID = category.id
        let minutes = category.defaultMinutes
        sessionMinutes = minutes
        pending = PendingStart(minutes: minutes, mode: timerMode, breakMinutes: breakMinutes, sessionMode: category.mode)
        isWaitingForStream = true
        player.play(category: category, shuffle: shuffle)
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // Don't start timer if stream already failed (needsRetry set by PlayerCore.handleLoadFailure).
            guard !self.player.needsRetry else { return }
            self.beginTimerWhenReady()
        }
    }

    func toggleSession() {
        switch timer.phase {
        case .idle, .finished:
            startDefaultSession()
        default:
            timer.togglePause()
            player.toggle()
        }
    }

    func resetSession() {
        recordPartialWork()
        pending = nil
        isWaitingForStream = false
        activeSessionMode = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        timer.reset()
        // Полная остановка: отменяет резолвы/stall/autoNext/fade —
        // воскрешение воспроизведения после сброса невозможно (аудит A-2).
        player.reset()
    }

    func setDuration(_ minutes: Int) {
        // Аудит A-5: во время перерыва НЕ обрываем его — новая длительность
        // только сохраняется (sessionMinutes → UserDefaults). Текущий перерыв
        // и следующая за ним work-фаза идут с параметрами, захваченными при
        // старте сессии: TimerEngine хранит их до следующего start и не
        // допускает точечной подмены workSeconds. Актуальное значение
        // гарантированно применяется при следующем полном рестарте
        // (setMode / новая сессия): timer.start получает текущий sessionMinutes.
        if timer.phase == .breakPhase {
            sessionMinutes = minutes
            return
        }
        recordPartialWork()
        sessionMinutes = minutes
        if timer.phase == .work {
            timer.start(minutes: minutes, mode: timerMode, breakMinutes: breakMinutes)
        }
    }

    func setMode(_ mode: TimerEngine.Mode) {
        timerModeRaw = mode.rawValue
        if timer.phase == .work || timer.phase == .breakPhase {
            recordPartialWork()
            timer.start(minutes: sessionMinutes, mode: mode, breakMinutes: breakMinutes)
        }
    }

    /// Вся запись статистики идёт через контроллер (колбэк onWorkPhaseCompleted),
    /// поэтому пропуск фазы UI должен звать сюда, а не в таймер напрямую.
    func skipPhase() {
        timer.skipPhase()
    }

    func setVolume(_ value: Float) {
        volume = value
    }

    func startDefaultSession() {
        guard timer.phase == .idle || timer.phase == .finished else { return }
        let category = selectedCategory ?? store.allCategories.first { !$0.tracks.isEmpty }
        if let category {
            startSession(category)
        }
    }

    func beginTimerWhenReady() {
        guard let start = pending else { return }
        pending = nil
        isWaitingForStream = false
        activeSessionMode = start.sessionMode
        fallbackTask?.cancel()
        fallbackTask = nil
        timer.start(minutes: start.minutes, mode: start.mode, breakMinutes: start.breakMinutes)
    }

    private func recordPartialWork() {
        guard timer.phase == .work else { return }
        let elapsedMinutes = Int((timer.total - timer.remaining) / 60)
        if elapsedMinutes >= 1 {
            stats.record(minutes: elapsedMinutes, mode: sessionModeForStats)
        }
    }
}
