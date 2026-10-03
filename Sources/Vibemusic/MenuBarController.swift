import AppKit
import Combine
import VibemusicCore

/// Строка меню на классическом AppKit NSStatusItem.
///
/// SwiftUI MenuBarExtra на текущей бета-сборке macOS уходит в бесконечный
/// цикл пересборки главного меню (makeMainMenu → preferences invalidate →
/// снова makeMainMenu, ~98% CPU). AppKit-путь обновляет пункт меню
/// напрямую, без SwiftUI-транзакций.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var items: [String: NSMenuItem] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?

    private weak var controller: SessionController?
    private weak var player: PlayerCore?

    private override init() {
        super.init()
    }

    func install(controller: SessionController, player: PlayerCore) {
        guard statusItem == nil else { return }
        self.controller = controller
        self.player = player

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = buildMenu()

        // Живые обновления — напрямую в AppKit, без SwiftUI-пересборок.
        let timerTicks = Publishers.MergeMany(
            controller.timer.$remaining.map { _ in () }.eraseToAnyPublisher(),
            controller.timer.$phase.map { _ in () }.eraseToAnyPublisher(),
            controller.timer.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            controller.timer.$completedCycles.map { _ in () }.eraseToAnyPublisher(),
            controller.$selectedCategoryID.map { _ in () }.eraseToAnyPublisher()
        ).eraseToAnyPublisher()

        timerTicks
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        Publishers.MergeMany(
            player.$current.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            player.$needsRetry.map { _ in () }.eraseToAnyPublisher()
        )
        .eraseToAnyPublisher()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &cancellables)

        // Настройка «Показывать таймер в строке меню».
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncVisibility()
            }
        }

        syncVisibility()
        refresh()
    }

    private var isShown: Bool {
        UserDefaults.standard.object(forKey: AppDefaults.Keys.menuBarEnabled) as? Bool
            ?? AppDefaults.menuBarEnabled
    }

    private func syncVisibility() {
        statusItem?.isVisible = isShown
    }

    // MARK: - Меню

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let definitions: [(String, String, Selector?, String)] = [
            ("status", "", nil, ""),
            ("toggle", "Начать сессию", #selector(toggleSession), ""),
            ("next", "Следующий трек", #selector(nextTrack), ""),
            ("prev", "Предыдущий трек", #selector(prevTrack), ""),
            ("open", "Открыть Vibemusic", #selector(openMain), ""),
            ("settings", "Настройки…", #selector(openSettings), ","),
            ("today", "Сегодня: —", nil, ""),
            ("quit", "Завершить Vibemusic", #selector(quitApp), "q"),
        ]
        for (index, definition) in definitions.enumerated() {
            if index == 1 || index == 4 || index == 6 {
                menu.addItem(.separator())
            }
            let (id, title, action, key) = definition
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.target = self
            menuItem.isEnabled = true
            items[id] = menuItem
            menu.addItem(menuItem)
        }
        return menu
    }

    private func refresh() {
        guard let controller, let player else { return }
        let timerEngine = controller.timer

        // Title статус-бара: остаток таймера или иконка.
        if timerEngine.phase == .work || timerEngine.phase == .breakPhase {
            let pauseMark = timerEngine.isPaused ? "⏸ " : ""
            statusItem?.button?.image = nil
            statusItem?.button?.title = pauseMark + Theme.timeString(timerEngine.remaining)
        } else {
            statusItem?.button?.title = ""
            statusItem?.button?.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Vibemusic"
            )
        }

        items["status"]?.title = statusLine()

        let isRunning = timerEngine.phase == .work || timerEngine.phase == .breakPhase
        items["toggle"]?.title = isRunning
            ? (timerEngine.isPaused ? "Возобновить" : "Пауза")
            : "Начать сессию"

        let trackTitle = player.current?.title ?? ""
        items["next"]?.title = trackTitle.isEmpty
            ? "Следующий трек"
            : "Следующий трек — \(shorten(trackTitle, 40))"

        let minutes = controller.stats.todayMinutes
        items["today"]?.title = minutes > 0
            ? "Сегодня: \(Theme.timeString(TimeInterval(minutes * 60)))"
            : "Сегодня: —"
    }

    private func statusLine() -> String {
        guard let controller, let player else { return "Vibemusic" }
        let timerEngine = controller.timer
        if timerEngine.phase == .work || timerEngine.phase == .breakPhase {
            let phaseName = timerEngine.phase == .breakPhase
                ? "Перерыв"
                : phaseName(for: controller.selectedCategory?.mode)
            var line = "\(phaseName): осталось \(Theme.timeString(timerEngine.remaining))"
            if controller.timerMode == .pomodoro, timerEngine.completedCycles > 0 {
                line += " · циклов: \(timerEngine.completedCycles)"
            }
            return line
        }
        if let current = player.current {
            return shorten(current.title, 60)
        }
        return "Сессия не активна"
    }

    private func phaseName(for mode: SessionMode?) -> String {
        switch mode {
        case .meditate: return "Медитация"
        case .sleep: return "Сон"
        case .wake: return "Утро"
        default: return "Фокус"
        }
    }

    private func shorten(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: - Действия

    @objc private func toggleSession() {
        controller?.toggleSession()
    }

    @objc private func nextTrack() {
        player?.next()
    }

    @objc private func prevTrack() {
        player?.previous()
    }

    @objc private func openMain() {
        (NSApp.delegate as? AppDelegate)?.openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
