import SwiftUI
import ServiceManagement
import VibemusicCore

struct SettingsView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var stats: StatsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(controller: controller)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            SessionSettingsTab(controller: controller)
                .tabItem { Label("Сессии", systemImage: "timer") }
            StatsSettingsTab(stats: stats)
                .tabItem { Label("Статистика", systemImage: "chart.bar") }
        }
        .frame(width: 520, height: 430)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var controller: SessionController
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("proxyEnabled") private var proxyEnabled = true
    @AppStorage("proxyURL") private var proxyURL = ProxyConfig.embeddedDefaultURL
    @State private var loginError: String?
    @State private var proxyTestResult: String?
    @State private var proxyTesting = false

    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { setLoginItem($0) }
                ))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Показывать таймер в строке меню", isOn: $menuBarEnabled)
            }

            Section("Прокси для YouTube") {
                Toggle("Использовать SOCKS5-прокси", isOn: $proxyEnabled)
                TextField("socks5://user:pass@host:port", text: $proxyURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack {
                    Button(proxyTesting ? "Проверяю…" : "Проверить соединение") {
                        testProxy()
                    }
                    .disabled(proxyTesting || proxyURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let proxyTestResult {
                        Text(proxyTestResult)
                            .font(.caption)
                            .foregroundStyle(proxyTestResult.hasPrefix("OK") ? Color.green : Color.red)
                    }
                }
                Text("Резолв ссылок и загрузка аудио идут одним маршрутом (напрямую или через прокси — что сработает первым, гонкой). Живые радио-потоки играются напрямую.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Воспроизведение") {
                Toggle("Перемешивать треки", isOn: $controller.shuffle)
                HStack {
                    Text("Громкость")
                    Slider(value: $controller.volume, in: 0...1)
                        .frame(maxWidth: 260)
                }
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }

    private func testProxy() {
        let candidate = proxyURL.trimmingCharacters(in: .whitespaces)
        guard let toolURL = ProxyConfig.toolURL(from: candidate) else {
            proxyTestResult = "Некорректный адрес"
            return
        }
        proxyTesting = true
        proxyTestResult = nil
        Task {
            let start = Date()
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try YTResolver.streamURL(for: "hLFtwxEqO-w", proxy: toolURL)
                }.value
                await MainActor.run {
                    proxyTestResult = "OK за \(String(format: "%.1f", Date().timeIntervalSince(start)))с"
                    proxyTesting = false
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    proxyTestResult = "Ошибка: \(String(message.prefix(120)))"
                    proxyTesting = false
                }
            }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Не удалось: \(error.localizedDescription). Приложение должно лежать в /Applications."
        }
    }
}

struct SessionSettingsTab: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        Form {
            Picker("Режим по умолчанию", selection: $controller.timerModeRaw) {
                Text("Обратный отсчёт").tag(TimerEngine.Mode.countdown.rawValue)
                Text("Помодоро").tag(TimerEngine.Mode.pomodoro.rawValue)
            }
            Picker("Длительность по умолчанию", selection: $controller.sessionMinutes) {
                ForEach([5, 10, 15, 20, 25, 30, 45, 50, 60, 90, 120, 180, 480], id: \.self) { minutes in
                    Text("\(Theme.shortDuration(minutes)) (\(minutes) мин)").tag(minutes)
                }
            }
            if controller.timerMode == .pomodoro {
                Picker("Перерыв", selection: $controller.breakMinutes) {
                    ForEach([5, 10, 15], id: \.self) { minutes in
                        Text("\(minutes) мин").tag(minutes)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }
}

struct StatsSettingsTab: View {
    @ObservedObject var stats: StatsStore
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 32) {
                statBlock("Всего", Theme.timeString(TimeInterval(stats.totalMinutes * 60)))
                statBlock("Сессий", "\(stats.sessionCount)")
                statBlock("Серия", "\(stats.currentStreak) дн.")
                statBlock("Сегодня", Theme.timeString(TimeInterval(stats.todayMinutes * 60)))
            }
            weekChart
            Spacer()
            HStack {
                Text("Учитываются завершённые фазы и сессии от 1 минуты")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Сбросить статистику") { confirmReset = true }
            }
        }
        .padding(22)
        .confirmationDialog("Удалить всю статистику?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { stats.reset() }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var weekChart: some View {
        let days = stats.lastDays(7)
        let maxMinutes = max(days.map(\.minutes).max() ?? 0, 1)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Последние 7 дней")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(days, id: \.day) { item in
                    VStack(spacing: 5) {
                        Text(item.minutes > 0 ? Theme.timeString(TimeInterval(item.minutes * 60)) : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.indigo.opacity(0.85), .purple.opacity(0.6)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: 26, height: 6 + CGFloat(item.minutes) / CGFloat(maxMinutes) * 110)
                        Text(formatter.string(from: item.day))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
