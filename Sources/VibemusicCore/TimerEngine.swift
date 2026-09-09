import Foundation
import os

@MainActor
public final class TimerEngine: ObservableObject {
    public enum Mode: String {
        case countdown, pomodoro
    }

    public enum Phase: Equatable {
        case idle, work, breakPhase, finished
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var remaining: TimeInterval = 0
    @Published public private(set) var total: TimeInterval = 0
    @Published public private(set) var completedCycles = 0
    @Published public private(set) var isPaused = false

    /// Injectable clock; tests substitute a deterministic fake.
    /// Deadline math always goes through this closure, never through Date() directly.
    public var clock: () -> Date = { Date() }

    /// Legacy property kept only for source compatibility with older call sites.
    /// It no longer participates in the time math: remaining is always derived
    /// from phaseDeadline vs clock, so the polling cadence cannot accumulate drift.
    /// The ticker itself always polls at a fixed 1 s interval.
    public var tickInterval: TimeInterval = 1

    public var bell: () -> Void = {}
    public var onSessionEnd: () -> Void = {}
    public var onWorkPhaseCompleted: ((Int) -> Void)?

    private var workSeconds: TimeInterval = 0
    private var breakSeconds: TimeInterval = 5 * 60
    private var mode: Mode = .countdown
    private var phaseDeadline = Date.distantPast
    private var hasStarted = false
    private nonisolated(unsafe) var ticker: Timer?
    private let logger = Logger(subsystem: "com.vibemusic.app", category: "timer")

    public init() {}

    deinit { ticker?.invalidate() }

    public func start(minutes: Int, mode: Mode, breakMinutes: Int) {
        workSeconds = TimeInterval(max(1, minutes)) * 60
        breakSeconds = TimeInterval(max(1, breakMinutes)) * 60
        self.mode = mode
        completedCycles = 0
        isPaused = false
        hasStarted = true
        beginPhase(.work)
    }

    public func togglePause() {
        guard phase == .work || phase == .breakPhase else { return }
        isPaused ? resume() : pause()
    }

    public func pause() {
        guard phase == .work || phase == .breakPhase, !isPaused else { return }
        isPaused = true
        remaining = remainingFromDeadline()
        stopTicker()
        logger.info("paused with remaining=\(self.remaining, format: .fixed(precision: 1))s")
    }

    public func resume() {
        guard phase == .work || phase == .breakPhase, isPaused else { return }
        isPaused = false
        phaseDeadline = clock().addingTimeInterval(remaining)
        startTicker()
        logger.info("resumed with remaining=\(self.remaining, format: .fixed(precision: 1))s")
    }

    public func reset() {
        stopTicker()
        phase = .idle
        isPaused = false
        completedCycles = 0
        total = hasStarted ? workSeconds : 0
        remaining = total
        logger.info("reset: total=\(self.total, format: .fixed(precision: 0))s, started before=\(self.hasStarted)")
    }

    public func skipPhase() {
        guard phase == .work || phase == .breakPhase else { return }
        if phase == .work {
            let elapsedMinutes = Int(max(0, total - currentRemaining()) / 60)
            if elapsedMinutes > 0 { onWorkPhaseCompleted?(elapsedMinutes) }
        }
        logger.info("phase skipped (phase=\(String(describing: self.phase)))")
        phaseCompleted()
    }

    /// Recomputes remaining from the phase deadline and advances the phase
    /// machine when the deadline has passed. Kept public so existing manual
    /// tick call sites keep compiling; with the injected clock it is fully
    /// deterministic in tests.
    public func simulateTick() {
        tick()
    }

    private func beginPhase(_ p: Phase) {
        phase = p
        total = (p == .breakPhase) ? breakSeconds : workSeconds
        remaining = total
        phaseDeadline = clock().addingTimeInterval(total)
        if isPaused { stopTicker() } else { startTicker() }
        logger.info("phase \(String(describing: p)) started: duration=\(self.total, format: .fixed(precision: 0))s")
    }

    private func phaseCompleted() {
        bell()
        switch phase {
        case .work:
            completedCycles += 1
            if mode == .pomodoro {
                beginPhase(.breakPhase)
            } else {
                finishSession()
            }
        case .breakPhase:
            beginPhase(.work)
        default:
            break
        }
    }

    private func finishSession() {
        stopTicker()
        phase = .finished
        isPaused = false
        remaining = 0
        logger.info("session finished after \(self.completedCycles) cycles")
        onSessionEnd()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard phase == .work || phase == .breakPhase, !isPaused else { return }
        let left = phaseDeadline.timeIntervalSince(clock())
        if left > 0 {
            remaining = left
            return
        }
        remaining = 0
        if phase == .work {
            onWorkPhaseCompleted?(Int(workSeconds / 60))
        }
        logger.info("phase deadline reached")
        phaseCompleted()
    }

    private func remainingFromDeadline() -> TimeInterval {
        max(0, phaseDeadline.timeIntervalSince(clock()))
    }

    /// Accurate remaining: while running it is derived from the deadline,
    /// while paused it is the value frozen at pause time.
    private func currentRemaining() -> TimeInterval {
        isPaused ? remaining : remainingFromDeadline()
    }
}
