import SwiftUI
import VibemusicCore

struct MenuBarLabel: View {
    @ObservedObject var timer: TimerEngine

    var body: some View {
        if timer.phase == .work || timer.phase == .breakPhase {
            Text((timer.isPaused ? "⏸ " : "") + Theme.timeString(timer.remaining))
                .monospacedDigit()
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var player: PlayerCore
    @ObservedObject var timer: TimerEngine
    @ObservedObject var stats: StatsStore

    var body: some View {
        Text(player.current?.title ?? "Vibemusic — фокус и спокойствие")
        if let channel = player.current?.channel {
            Text(channel)
        }
        Divider()
        if timer.phase == .work || timer.phase == .breakPhase {
            Text("\(phaseLabel): осталось \(Theme.timeString(timer.remaining))")
            if controller.timerMode == .pomodoro {
                Text("Завершено циклов: \(timer.completedCycles)")
            }
        } else {
            Text("Сессия не активна")
        }
        Divider()
        Button(player.isPlaying ? "Пауза" : "Играть") { controller.toggleSession() }
        Button("Следующий трек") { player.next() }
        Button("Предыдущий трек") { player.previous() }
        Divider()
        Button("Открыть Vibemusic") {
            (NSApp.delegate as? AppDelegate)?.openMain?()
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Настройки…") { openSettings() }
        Divider()
        if stats.todayMinutes > 0 {
            Text("Сегодня: \(Theme.timeString(TimeInterval(stats.todayMinutes * 60)))")
            Divider()
        }
        Button("Завершить Vibemusic") { NSApp.terminate(nil) }
    }

    private var phaseLabel: String {
        if timer.phase == .breakPhase { return "Перерыв" }
        switch controller.selectedCategory?.mode {
        case .meditate: return "Медитация"
        case .sleep: return "Сон"
        case .wake: return "Утро"
        default: return "Фокус"
        }
    }

    private func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
