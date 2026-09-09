import Foundation
import Testing
import VibemusicCore
@testable import Vibemusic

// MARK: - Утилиты

/// Мутируемый бокс даты — инжектируемые часы для TimerEngine.
/// Класс без изоляции: всё выполняется на главном потоке синхронно.
private final class ClockBox {
    var now = Date(timeIntervalSinceReferenceDate: 100_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Изолированный UserDefaults-сьют с уникальным именем домена.
private final class TestDefaults {
    let name = "vibemusic-session-tests-" + UUID().uuidString
    let suite: UserDefaults

    init() {
        suite = UserDefaults(suiteName: name)!
    }

    func removeAll() {
        for key in suite.dictionaryRepresentation().keys {
            suite.removeObject(forKey: key)
        }
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@MainActor
private func makeController(
    clock: ClockBox,
    defaults: UserDefaults
) -> (controller: SessionController, timer: TimerEngine, stats: StatsStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LibraryStore(directory: directory)
    let player = PlayerCore()
    let timer = TimerEngine()
    timer.clock = { clock.now }
    let stats = StatsStore(directory: directory)
    let controller = SessionController(
        store: store,
        player: player,
        timer: timer,
        stats: stats,
        defaults: defaults,
        warmupEnabled: false
    )
    return (controller, timer, stats)
}

@MainActor
private func makeCategory(id: String, mode: SessionMode, minutes: Int) -> MusicCategory {
    MusicCategory(
        id: id,
        title: id,
        mode: mode,
        defaultMinutes: minutes,
        tracks: [Track(id: "trk-" + id, title: "Track")]
    )
}

// MARK: - A-6: статистика пишет режим категории СТАРТА

@MainActor @Test func workPhaseRecordsStartCategoryModeNotCurrent() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, stats) = makeController(clock: clock, defaults: defaults.suite)

    let meditate = makeCategory(id: "meditate-session", mode: .meditate, minutes: 10)
    controller.startSession(meditate)
    controller.beginTimerWhenReady()
    #expect(timer.phase == .work)

    // Категория сменилась, пока старая сессия ещё в work-фазе
    // (стрим новой категории не готов, таймер не перезапущен).
    let work = makeCategory(id: "work-session", mode: .focus, minutes: 50)
    controller.select(work)
    #expect(controller.selectedCategoryID == "work-session")

    clock.advance(10 * 60)
    timer.simulateTick()

    #expect(stats.records.count == 1)
    #expect(stats.records.last?.mode == .meditate)
    #expect(stats.records.last?.minutes == 10)
}

// MARK: - A-5: setMode сохраняет частичные минуты

@MainActor @Test func setModeRecordsPartialWorkMinutes() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, stats) = makeController(clock: clock, defaults: defaults.suite)

    let focus = makeCategory(id: "focus-session", mode: .focus, minutes: 25)
    controller.startSession(focus)
    controller.beginTimerWhenReady()

    clock.advance(5 * 60 + 30)
    timer.simulateTick()
    #expect(stats.records.isEmpty)

    controller.setMode(.countdown)

    #expect(stats.records.count == 1)
    #expect(stats.records.last?.minutes == 5)
    #expect(stats.records.last?.mode == .focus)
    #expect(timer.phase == .work)
    #expect(timer.total == 25 * 60)
}

// MARK: - A-5: setDuration не обрывает перерыв

@MainActor @Test func setDurationDuringBreakDoesNotInterruptBreak() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, stats) = makeController(clock: clock, defaults: defaults.suite)

    let cat = makeCategory(id: "pomodoro-session", mode: .focus, minutes: 10)
    controller.startSession(cat)
    controller.beginTimerWhenReady()

    clock.advance(10 * 60)
    timer.simulateTick()
    #expect(timer.phase == .breakPhase)
    #expect(timer.total == 5 * 60)

    controller.setDuration(30)

    #expect(timer.phase == .breakPhase)
    #expect(timer.total == 5 * 60)
    #expect(timer.remaining == 5 * 60)
    #expect(controller.sessionMinutes == 30)
    #expect(defaults.suite.object(forKey: AppDefaults.Keys.sessionMinutes) as? Int == 30)
    #expect(stats.records.count == 1)

    // Новая длительность подхватывается при следующем рестарте (start).
    controller.setMode(.countdown)
    #expect(timer.phase == .work)
    #expect(timer.total == 30 * 60)
}

// MARK: - skipPhase: обёртка контроллера

@MainActor @Test func skipPhaseWrapperDelegatesToTimerAndRecordsStats() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, stats) = makeController(clock: clock, defaults: defaults.suite)

    let cat = makeCategory(id: "skip-session", mode: .focus, minutes: 10)
    controller.startSession(cat)
    controller.beginTimerWhenReady()

    clock.advance(90)
    controller.skipPhase()

    #expect(timer.phase == .breakPhase)
    #expect(timer.completedCycles == 1)
    #expect(stats.records.count == 1)
    #expect(stats.records.last?.minutes == 1)
    #expect(stats.records.last?.mode == .focus)
}

// MARK: - C-6: миграция ключей UserDefaults

@MainActor @Test func migratesLegacyUserDefaultsKeys() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let suite = defaults.suite

    suite.set(42, forKey: AppDefaults.Keys.Legacy.sessionMinutes)
    suite.set("countdown", forKey: AppDefaults.Keys.Legacy.timerMode)
    suite.set(7, forKey: AppDefaults.Keys.Legacy.breakMinutes)
    suite.set(false, forKey: AppDefaults.Keys.Legacy.shuffle)
    suite.set(Float(0.5), forKey: AppDefaults.Keys.Legacy.volume)

    let (controller, _, _) = makeController(clock: ClockBox(), defaults: suite)

    #expect(controller.sessionMinutes == 42)
    #expect(controller.timerModeRaw == "countdown")
    #expect(controller.breakMinutes == 7)
    #expect(controller.shuffle == false)
    #expect(controller.volume == 0.5)

    #expect(suite.object(forKey: AppDefaults.Keys.sessionMinutes) as? Int == 42)
    #expect(suite.string(forKey: AppDefaults.Keys.timerMode) == "countdown")
    #expect(suite.object(forKey: AppDefaults.Keys.breakMinutes) as? Int == 7)
    #expect(suite.object(forKey: AppDefaults.Keys.shuffle) as? Bool == false)
    #expect(suite.object(forKey: AppDefaults.Keys.volume) as? Float == 0.5)

    let legacyKeys = [
        AppDefaults.Keys.Legacy.sessionMinutes,
        AppDefaults.Keys.Legacy.timerMode,
        AppDefaults.Keys.Legacy.breakMinutes,
        AppDefaults.Keys.Legacy.shuffle,
        AppDefaults.Keys.Legacy.volume,
    ]
    for key in legacyKeys {
        #expect(suite.object(forKey: key) == nil)
    }
}
