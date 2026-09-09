import Foundation
import Testing
@testable import VibemusicCore

/// Mutable date box shared with the engine's injected clock closure.
/// Plain (non-Sendable) class: everything stays on the main thread and
/// synchronous, so no isolation annotations are needed.
private final class ClockBox {
    var now = Date(timeIntervalSinceReferenceDate: 100_000)
}

@MainActor
private func makeEngine(_ clock: ClockBox) -> TimerEngine {
    let engine = TimerEngine()
    engine.clock = { clock.now }
    return engine
}

@MainActor
private func advance(_ clock: ClockBox, _ seconds: TimeInterval) {
    clock.now = clock.now.addingTimeInterval(seconds)
}

@MainActor @Test func countdownCompletesAndFiresSessionEnd() {
    let clock = ClockBox()
    let engine = makeEngine(clock)
    var bells = 0
    var sessionEnds = 0
    var workMinutes: [Int] = []
    engine.bell = { bells += 1 }
    engine.onSessionEnd = { sessionEnds += 1 }
    engine.onWorkPhaseCompleted = { workMinutes.append($0) }

    engine.start(minutes: 50, mode: .countdown, breakMinutes: 5)
    #expect(engine.phase == .work)
    #expect(engine.remaining == 3000)

    advance(clock, 1000)
    engine.simulateTick()
    #expect(abs(engine.remaining - 2000) <= 1)
    #expect(engine.phase == .work)

    advance(clock, 2000)
    engine.simulateTick()
    #expect(engine.remaining <= 1)
    #expect(engine.phase == .finished)
    #expect(engine.isPaused == false)
    #expect(bells == 1)
    #expect(sessionEnds == 1)
    #expect(workMinutes == [50])
}

@MainActor @Test func deadlineMathAccumulatesNoDrift() {
    let clock = ClockBox()
    let engine = makeEngine(clock)
    engine.start(minutes: 30, mode: .countdown, breakMinutes: 5)

    for _ in 0..<20 {
        advance(clock, 50)
        engine.simulateTick()
    }
    #expect(abs(engine.remaining - 800) <= 1)
    #expect(engine.phase == .work)

    advance(clock, 799)
    engine.simulateTick()
    #expect(abs(engine.remaining - 1) <= 1)
    #expect(engine.phase == .work)

    advance(clock, 2)
    engine.simulateTick()
    #expect(engine.phase == .finished)
    #expect(engine.remaining <= 1)
}

@MainActor @Test func pomodoroCyclesPhases() {
    let clock = ClockBox()
    let engine = makeEngine(clock)
    engine.tickInterval = 30
    var bells = 0
    var workMinutes: [Int] = []
    engine.bell = { bells += 1 }
    engine.onWorkPhaseCompleted = { workMinutes.append($0) }

    engine.start(minutes: 1, mode: .pomodoro, breakMinutes: 1)
    #expect(engine.phase == .work)
    #expect(engine.remaining == 60)
    #expect(engine.total == 60)

    advance(clock, 60)
    engine.simulateTick()
    #expect(engine.phase == .breakPhase)
    #expect(engine.remaining == 60)
    #expect(engine.total == 60)
    #expect(engine.completedCycles == 1)
    #expect(bells == 1)
    #expect(workMinutes == [1])

    advance(clock, 60)
    engine.simulateTick()
    #expect(engine.phase == .work)
    #expect(engine.remaining == 60)
    #expect(engine.completedCycles == 1)
    #expect(bells == 2)

    advance(clock, 60)
    engine.simulateTick()
    #expect(engine.phase == .breakPhase)
    #expect(engine.completedCycles == 2)
    #expect(bells == 3)
    #expect(workMinutes == [1, 1])
}

@MainActor @Test func pauseBlocksTicks() {
    let clock = ClockBox()
    let engine = makeEngine(clock)
    engine.start(minutes: 5, mode: .countdown, breakMinutes: 5)
    #expect(engine.remaining == 300)

    advance(clock, 10)
    engine.simulateTick()
    #expect(abs(engine.remaining - 290) <= 1)

    engine.pause()
    let frozen = engine.remaining
    advance(clock, 100)
    engine.simulateTick()
    #expect(engine.remaining == frozen)
    #expect(engine.isPaused == true)

    engine.resume()
    advance(clock, 1)
    engine.simulateTick()
    #expect(abs(engine.remaining - (frozen - 1)) <= 1)

    advance(clock, frozen)
    engine.simulateTick()
    #expect(engine.phase == .finished)
    #expect(engine.remaining <= 1)
}

@MainActor @Test func skipPhaseRecordsPartialMinutesOnly() {
    let clock = ClockBox()
    let engine = makeEngine(clock)
    var workMinutes: [Int] = []
    engine.onWorkPhaseCompleted = { workMinutes.append($0) }

    engine.start(minutes: 10, mode: .pomodoro, breakMinutes: 5)
    advance(clock, 30)
    engine.skipPhase()
    #expect(engine.phase == .breakPhase)
    #expect(workMinutes.isEmpty)

    engine.skipPhase()
    #expect(engine.phase == .work)
    #expect(engine.remaining == 600)

    advance(clock, 90)
    engine.skipPhase()
    #expect(engine.phase == .breakPhase)
    #expect(workMinutes == [1])
}

@MainActor @Test func skipWhilePausedKeepsPhaseConsistent() {
    let clock = ClockBox()
    let engine = makeEngine(clock)
    engine.start(minutes: 10, mode: .pomodoro, breakMinutes: 5)
    advance(clock, 120)
    engine.pause()
    engine.skipPhase()
    #expect(engine.phase == .breakPhase)
    #expect(engine.isPaused == true)
    #expect(engine.remaining == 300)

    engine.resume()
    #expect(engine.isPaused == false)
    advance(clock, 300)
    engine.simulateTick()
    #expect(engine.phase == .work)
}

@MainActor @Test func resetRestoresCleanInvariants() {
    let fresh = TimerEngine()
    fresh.reset()
    #expect(fresh.phase == .idle)
    #expect(fresh.isPaused == false)
    #expect(fresh.completedCycles == 0)
    #expect(fresh.total == 0)
    #expect(fresh.remaining == 0)

    let clock = ClockBox()
    let engine = makeEngine(clock)
    engine.start(minutes: 25, mode: .pomodoro, breakMinutes: 5)
    advance(clock, 90)
    engine.pause()
    engine.reset()

    #expect(engine.phase == .idle)
    #expect(engine.isPaused == false)
    #expect(engine.completedCycles == 0)
    #expect(engine.total == 25 * 60)
    #expect(engine.remaining == 25 * 60)

    advance(clock, 10_000)
    engine.simulateTick()
    #expect(engine.phase == .idle)
    #expect(engine.remaining == 25 * 60)
}
