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
    @Published var shuffle: Bool { didSet { defaults.set(shuffle, forKey: Keys.shuffle) } }
    @Published var volume: Float { didSet { player.setVolume(volume); defaults.set(volume, forKey: Keys.volume) } }
    @Published var sessionMinutes: Int { didSet { defaults.set(sessionMinutes, forKey: Keys.sessionMinutes) } }
    @Published var timerModeRaw: String { didSet { defaults.set(timerModeRaw, forKey: Keys.timerMode) } }
    @Published var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: Keys.breakMinutes) } }

    var timerMode: TimerEngine.Mode { TimerEngine.Mode(rawValue: timerModeRaw) ?? .countdown }

    private struct PendingStart {
        let minutes: Int
        let mode: TimerEngine.Mode
        let breakMinutes: Int
    }

    private var pending: PendingStart?
    private var fallbackTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let sessionMinutes = "sessionMinutes"
        static let timerMode = "timerMode"
        static let breakMinutes = "breakMinutes"
        static let shuffle = "shuffle"
        static let volume = "volume"
    }

    init(store: LibraryStore, player: PlayerCore, timer: TimerEngine, stats: StatsStore) {
        self.store = store
        self.player = player
        self.timer = timer
        self.stats = stats

        shuffle = defaults.object(forKey: Keys.shuffle) as? Bool ?? true
        volume = defaults.object(forKey: Keys.volume) as? Float ?? 0.85
        sessionMinutes = defaults.object(forKey: Keys.sessionMinutes) as? Int ?? 50
        timerModeRaw = defaults.string(forKey: Keys.timerMode) ?? "pomodoro"
        breakMinutes = defaults.object(forKey: Keys.breakMinutes) as? Int ?? 5

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
            self.stats.record(minutes: minutes, mode: self.selectedCategory?.mode ?? .focus)
        }

        player.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                if playing { self?.beginTimerWhenReady() }
            }
            .store(in: &cancellables)

        player.setVolume(volume)
        if let firstCat = store.category(id: "work") ?? store.curated.first {
            player.warmup(category: firstCat)
        }
    }

    var selectedCategory: MusicCategory? {
        selectedCategoryID.flatMap { store.category(id: $0) }
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
        pending = PendingStart(minutes: minutes, mode: timerMode, breakMinutes: breakMinutes)
        isWaitingForStream = true
        player.play(category: category, shuffle: shuffle)
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.beginTimerWhenReady()
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
        fallbackTask?.cancel()
        fallbackTask = nil
        timer.reset()
        player.stop(fade: false)
    }

    func setDuration(_ minutes: Int) {
        recordPartialWork()
        sessionMinutes = minutes
        if timer.phase == .work || timer.phase == .breakPhase {
            timer.start(minutes: minutes, mode: timerMode, breakMinutes: breakMinutes)
        }
    }

    func setMode(_ mode: TimerEngine.Mode) {
        timerModeRaw = mode.rawValue
        if timer.phase == .work || timer.phase == .breakPhase {
            timer.start(minutes: sessionMinutes, mode: mode, breakMinutes: breakMinutes)
        }
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

    private func beginTimerWhenReady() {
        guard let start = pending else { return }
        pending = nil
        isWaitingForStream = false
        fallbackTask?.cancel()
        fallbackTask = nil
        timer.start(minutes: start.minutes, mode: start.mode, breakMinutes: start.breakMinutes)
    }

    private func recordPartialWork() {
        guard timer.phase == .work else { return }
        let elapsedMinutes = Int((timer.total - timer.remaining) / 60)
        if elapsedMinutes >= 1 {
            stats.record(minutes: elapsedMinutes, mode: selectedCategory?.mode ?? .focus)
        }
    }
}
