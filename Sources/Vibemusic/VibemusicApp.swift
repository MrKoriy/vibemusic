import SwiftUI
import AppKit
import VibemusicCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMain: (() -> Void)?

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMain?()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

@main
struct VibemusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store: LibraryStore
    @StateObject private var stats: StatsStore
    @StateObject private var player: PlayerCore
    @StateObject private var timer: TimerEngine
    @StateObject private var controller: SessionController

    init() {
        CLIBootstrap.handleIfNeeded()
        // Разовая миграция со старого ключа "menuBarEnabled" (C-6): если
        // нового ключа нет, а легаси-значение записано — переносим.
        _ = AppDefaults.migratedValue(
            UserDefaults.standard,
            newKey: AppDefaults.Keys.menuBarEnabled,
            legacyKey: AppDefaults.Keys.Legacy.menuBarEnabled,
            fallback: AppDefaults.menuBarEnabled
        )
        let store = LibraryStore()
        let stats = StatsStore()
        let player = PlayerCore()
        let timer = TimerEngine()
        let controller = SessionController(store: store, player: player, timer: timer, stats: stats)
        _store = StateObject(wrappedValue: store)
        _stats = StateObject(wrappedValue: stats)
        _player = StateObject(wrappedValue: player)
        _timer = StateObject(wrappedValue: timer)
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1040, height: 780)
        .environmentObject(store)
        .environmentObject(stats)
        .environmentObject(player)
        .environmentObject(timer)
        .environmentObject(controller)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Открыть главное окно") {
                    NSApp.activate(ignoringOtherApps: true)
                    (NSApp.delegate as? AppDelegate)?.openMain?()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView(controller: controller, stats: stats)
        }
    }
}
