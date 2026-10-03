import Foundation
import Testing
import VibemusicCore
@testable import Vibemusic

// MARK: - Утилиты

private final class ClockBox {
    var now = Date(timeIntervalSinceReferenceDate: 100_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private final class TestDefaults {
    let name = "vibemusic-sync-tests-" + UUID().uuidString
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
) -> (controller: SessionController, timer: TimerEngine, player: PlayerCore, stats: StatsStore) {
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
    return (controller, timer, player, stats)
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

/// Сессия с уже играющим плеером (пропускаем загрузку стрима).
@MainActor
private func startRunningSession(
    _ controller: SessionController,
    _ timer: TimerEngine,
    clock: ClockBox,
    minutes: Int = 10
) {
    let category = makeCategory(id: "sync-cat", mode: .focus, minutes: minutes)
    controller.startSession(category)
    controller.beginTimerWhenReady()
    #expect(timer.phase == .work)
}

// MARK: - Пауза по намерению

@MainActor @Test func pauseSessionStopsTimerAndPlayerTogether() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, player, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    clock.advance(30)
    timer.simulateTick()
    #expect(abs(timer.remaining - 570) <= 1)

    // Ключевой сценарий рассинхрона: плеер «играет», пользователь жмёт паузу.
    controller.playbackStateChanged(playing: true)
    controller.pauseSession()

    #expect(controller.isSessionPaused == true)
    #expect(timer.isPaused == true)
    #expect(player.playIntent == .paused)

    // Пока пауза — отсчёт заморожен.
    clock.advance(100)
    timer.simulateTick()
    #expect(abs(timer.remaining - 570) <= 1)
}

@MainActor @Test func resumeSessionStartsTimerAndPlayerTogether() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, player, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    controller.pauseSession()
    clock.advance(500)
    timer.simulateTick()

    controller.resumeSession()
    #expect(controller.isSessionPaused == false)
    #expect(timer.isPaused == false)
    #expect(player.playIntent == .playing)

    clock.advance(5)
    timer.simulateTick()
    #expect(abs(timer.remaining - 595) <= 1)
}

// MARK: - Буферизация: таймер не тикает, пока песня не играет

@MainActor @Test func bufferingSuspendsTimerAndRecoveryResumesIt() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, _, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    // Стрим заикался: плеер встал (буферизация).
    controller.playbackStateChanged(playing: false)
    #expect(timer.isSuspended == true)
    #expect(timer.isPaused == false)

    clock.advance(120)
    timer.simulateTick()
    // Отсчёт стоит, пока нет звука — «песня на паузе, таймер не хуярит».
    #expect(abs(timer.remaining - 600) <= 1)

    // Звук вернулся — отсчёт продолжается с того же места.
    controller.playbackStateChanged(playing: true)
    #expect(timer.isSuspended == false)
    clock.advance(10)
    timer.simulateTick()
    #expect(abs(timer.remaining - 590) <= 1)
}

@MainActor @Test func playbackStopDuringUserPauseDoesNotSuspend() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, _, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    controller.pauseSession()
    controller.playbackStateChanged(playing: false)
    // Пауза пользователя остаётся паузой, не «двойной» заморозкой.
    #expect(timer.isPaused == true)
    #expect(timer.isSuspended == false)
}

@MainActor @Test func autoResurrectedPlaybackIsSilencedDuringUserPause() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, player, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    controller.pauseSession()
    // autoNext/гонки загрузили трек и он сам заиграл — гасим: пользователь на паузе.
    player.resumePlayback()
    controller.playbackStateChanged(playing: true)

    #expect(controller.isSessionPaused == true)
    #expect(player.playIntent == .paused)
    #expect(timer.isPaused == true)
}

// MARK: - Пауза во время подготовки стрима

@MainActor @Test func pauseDuringStreamPreparationDoesNotRestartSession() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, player, _) = makeController(clock: clock, defaults: defaults.suite)

    // Сессия запущена, стрим ещё грузится (pending, таймер idle).
    let category = makeCategory(id: "prep-cat", mode: .focus, minutes: 25)
    controller.startSession(category)
    #expect(controller.isWaitingForStream == true)

    // Пробел во время «Подготовка» = пауза, НЕ перезапуск сессии.
    controller.toggleSession()
    #expect(controller.isSessionPaused == true)
    #expect(controller.isWaitingForStream == true)
    #expect(timer.phase == .idle)
    #expect(player.playIntent == .paused)

    // Стрим стал готов и заиграл — пауза пользователя сильнее.
    controller.playbackStateChanged(playing: true)
    #expect(player.playIntent == .paused)
    #expect(timer.phase == .idle)

    // Пробел снова: продолжение — таймер стартует.
    controller.toggleSession()
    #expect(controller.isSessionPaused == false)
    #expect(player.playIntent == .playing)
    controller.playbackStateChanged(playing: true)
    #expect(timer.phase == .work)
    #expect(timer.isPaused == false)
}

// MARK: - Медиа-клавиши

@MainActor @Test func remotePlayPauseRouteThroughIntent() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, player, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    // Пауза с наушников, пока плеер буферизует (isPlaying == false):
    // раньше пауза просто не срабатывала и музыка потом врубалась.
    controller.playbackStateChanged(playing: false)
    controller.remotePause()
    #expect(controller.isSessionPaused == true)
    #expect(timer.isPaused == true)

    // Play с наушников во время буферизации — сессия продолжается,
    // не перезапускается с нуля.
    controller.remotePlay()
    #expect(controller.isSessionPaused == false)
    #expect(timer.isPaused == false)
    #expect(timer.remaining > 590)
    #expect(player.playIntent == .playing)
}

// MARK: - TimerEngine.suspend

@MainActor @Test func timerSuspendFreezesAndUnsuspendContinues() {
    let clock = ClockBox()
    let engine = TimerEngine()
    engine.clock = { clock.now }
    engine.start(minutes: 10, mode: .countdown, breakMinutes: 5)

    clock.advance(100)
    engine.simulateTick()
    #expect(abs(engine.remaining - 500) <= 1)

    engine.suspend()
    #expect(engine.isSuspended == true)
    #expect(engine.isFrozen == true)

    clock.advance(200)
    engine.simulateTick()
    #expect(abs(engine.remaining - 500) <= 1)

    engine.unsuspend()
    #expect(engine.isSuspended == false)
    clock.advance(10)
    engine.simulateTick()
    #expect(abs(engine.remaining - 490) <= 1)
}

@MainActor @Test func timerSuspendIgnoredWhileUserPaused() {
    let clock = ClockBox()
    let engine = TimerEngine()
    engine.clock = { clock.now }
    engine.start(minutes: 10, mode: .countdown, breakMinutes: 5)

    engine.pause()
    engine.suspend()
    #expect(engine.isPaused == true)
    #expect(engine.isSuspended == false)

    // resume снимает обе заморозки.
    clock.advance(100)
    engine.suspend() // уже есть пауза — игнор
    engine.resume()
    #expect(engine.isPaused == false)
    #expect(engine.isSuspended == false)
}

// MARK: - setDuration/setMode не снимают паузу

@MainActor @Test func setDurationDuringUserPauseKeepsPause() {
    let defaults = TestDefaults()
    defer { defaults.removeAll() }
    let clock = ClockBox()
    let (controller, timer, player, _) = makeController(clock: clock, defaults: defaults.suite)
    startRunningSession(controller, timer, clock: clock)

    controller.pauseSession()
    controller.setDuration(30)

    #expect(controller.isSessionPaused == true)
    #expect(timer.isPaused == true)
    #expect(timer.total == 30 * 60)
    #expect(player.playIntent == .paused)
}
