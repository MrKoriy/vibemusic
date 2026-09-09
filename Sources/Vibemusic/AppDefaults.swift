import Foundation

/// Единый источник дефолтов, пресетов и ключей настроек (аудит E-8, E-9, C-6).
enum AppDefaults {
    // Дефолты
    static let volume: Float = 0.85
    static let shuffle: Bool = true
    static let timerModeRaw = "pomodoro"
    static let sessionMinutes = 50
    static let breakMinutes = 5
    static let menuBarEnabled = true

    // Пресеты длительностей — один источник истины для главного экрана и настроек
    static let presetDurations: [Int] = [15, 30, 60, 120]
    static let allDurations: [Int] = [5, 10, 15, 20, 25, 30, 45, 50, 60, 90, 120, 180, 240, 480]
    static let breakChoices: [Int] = [5, 10, 15]

    /// Миграция значения с легаси-ключа на новый (аудит C-6): приоритет у
    /// нового ключа; при его отсутствии берётся легаси (значение переносится
    /// в новый ключ), легаси-ключ удаляется в любом случае.
    static func migratedValue<T>(
        _ defaults: UserDefaults,
        newKey: String,
        legacyKey: String,
        fallback: T
    ) -> T {
        if let stored = defaults.object(forKey: newKey) as? T {
            defaults.removeObject(forKey: legacyKey)
            return stored
        }
        defer { defaults.removeObject(forKey: legacyKey) }
        guard let legacy = defaults.object(forKey: legacyKey) as? T else { return fallback }
        defaults.set(legacy, forKey: newKey)
        return legacy
    }

    enum Keys {
        static let sessionMinutes = "com.vibemusic.session.minutes"
        static let timerMode = "com.vibemusic.session.timerMode"
        static let breakMinutes = "com.vibemusic.session.breakMinutes"
        static let shuffle = "com.vibemusic.session.shuffle"
        static let volume = "com.vibemusic.session.volume"
        static let menuBarEnabled = "com.vibemusic.ui.menuBarEnabled"

        // Легаси-ключи до миграции (аудит C-6)
        enum Legacy {
            static let sessionMinutes = "sessionMinutes"
            static let timerMode = "timerMode"
            static let breakMinutes = "breakMinutes"
            static let shuffle = "shuffle"
            static let volume = "volume"
            static let menuBarEnabled = "menuBarEnabled"
        }
    }
}
