import Foundation

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

    public var tickInterval: TimeInterval = 1
    public var bell: () -> Void = {}
    public var onSessionEnd: () -> Void = {}
    public var onWorkPhaseCompleted: ((Int) -> Void)?

    private var workSeconds: TimeInterval = 0
    private var breakSeconds: TimeInterval = 5 * 60
    private var mode: Mode = .countdown
    private nonisolated(unsafe) var ticker: Timer?

    public init() {}

    deinit { ticker?.invalidate() }

    public func start(minutes: Int, mode: Mode, breakMinutes: Int) {
        workSeconds = TimeInterval(max(1, minutes)) * 60
        breakSeconds = TimeInterval(max(1, breakMinutes)) * 60
        self.mode = mode
        completedCycles = 0
        isPaused = false
        beginPhase(.work)
    }

    public func togglePause() {
        guard phase == .work || phase == .breakPhase else { return }
        isPaused ? resume() : pause()
    }

    public func pause() {
        isPaused = true
        stopTicker()
    }

    public func resume() {
        isPaused = false
        startTicker()
    }

    public func reset() {
        stopTicker()
        phase = .idle
        total = max(workSeconds, 1)
        remaining = workSeconds
        isPaused = false
        completedCycles = 0
    }

    public func skipPhase() {
        guard phase == .work || phase == .breakPhase else { return }
        if phase == .work {
            let elapsedMinutes = Int((total - remaining) / 60)
            if elapsedMinutes > 0 { onWorkPhaseCompleted?(elapsedMinutes) }
        }
        phaseCompleted()
    }

    public func simulateTick() {
        tick()
    }

    private func beginPhase(_ p: Phase) {
        phase = p
        total = (p == .breakPhase) ? breakSeconds : workSeconds
        remaining = total
        startTicker()
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
        onSessionEnd()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
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
        guard !isPaused, phase == .work || phase == .breakPhase else { return }
        remaining -= tickInterval
        if remaining <= 0 {
            remaining = 0
            if phase == .work {
                onWorkPhaseCompleted?(Int(workSeconds / 60))
            }
            phaseCompleted()
        }
    }
}
