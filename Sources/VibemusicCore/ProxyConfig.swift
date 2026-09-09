import Foundation

/// Конфигурация SOCKS5-прокси. Хранится в UserDefaults, редактируется в настройках.
/// Прокси используется и для резолва ссылок (yt-dlp), и для загрузки аудио (curl),
/// причём оба шага всегда идут одним маршрутом: googlevideo привязывает ссылку к IP.
public struct ProxyConfig: Equatable, Sendable {
    /// Режим маршрутизации: auto — гонка прямой/прокси, forced — только прокси,
    /// direct — только прямое соединение.
    public enum Mode: String, Codable, Sendable {
        case auto
        case forced
        case direct
    }

    public var enabled: Bool
    public var url: String
    public var mode: Mode

    /// Прокси задаётся в настройках приложения (не хардкодим секреты в репозитории).
    public static let embeddedDefaultURL = ""

    static let enabledKey = "com.vibemusic.proxy.enabled"
    static let urlKey = "com.vibemusic.proxy.url"
    static let modeKey = "com.vibemusic.proxy.mode"
    static let legacyEnabledKey = "proxyEnabled"
    static let legacyURLKey = "proxyURL"

    public init(enabled: Bool, url: String, mode: Mode = .auto) {
        self.enabled = enabled
        self.url = url
        self.mode = mode
    }

    /// Переносит значения со старых ключей proxyEnabled/proxyURL на новые
    /// com.vibemusic.proxy.*: нового нет, старый есть → перенести, старый удалить.
    static func migrateLegacyKeys(defaults: UserDefaults) {
        if defaults.object(forKey: enabledKey) == nil,
           let legacyEnabled = defaults.object(forKey: legacyEnabledKey) as? Bool {
            defaults.set(legacyEnabled, forKey: enabledKey)
            defaults.removeObject(forKey: legacyEnabledKey)
        }
        if defaults.string(forKey: urlKey) == nil,
           let legacyURL = defaults.string(forKey: legacyURLKey) {
            defaults.set(legacyURL, forKey: urlKey)
            defaults.removeObject(forKey: legacyURLKey)
        }
    }

    public static func load(defaults: UserDefaults = .standard) -> ProxyConfig {
        migrateLegacyKeys(defaults: defaults)
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let url = defaults.string(forKey: urlKey) ?? embeddedDefaultURL
        let mode = defaults.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .auto
        var config = ProxyConfig(enabled: enabled, url: url, mode: mode)
        // Пустой или невалидный URL означает, что прокси фактически не работает.
        if !config.isValid {
            config.enabled = false
        }
        return config
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(url, forKey: Self.urlKey)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    /// URL для yt-dlp/curl: socks5:// → socks5h:// (DNS резолвим через прокси).
    public static func toolURL(from raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("socks5://") {
            return "socks5h://" + value.dropFirst("socks5://".count)
        }
        return value
    }

    /// Отпечаток маршрута прокси: scheme://host:port без учётных данных.
    /// nil — если строка не разбирается на схему и хост.
    static func fingerprint(ofToolURL toolURL: String) -> String? {
        guard let components = URLComponents(string: toolURL),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Готовый URL для инструментов с учётом режима:
    /// direct → nil; forced → URL если валиден, иначе nil; auto → как раньше.
    public var toolURL: String? {
        switch mode {
        case .direct:
            return nil
        case .forced:
            guard isValid else { return nil }
            return Self.toolURL(from: url)
        case .auto:
            guard enabled else { return nil }
            return Self.toolURL(from: url)
        }
    }

    /// Отпечаток эффективного маршрута: scheme://host:port без кредов.
    /// nil — когда инструменты идут без прокси (выключен, direct или невалидный URL).
    public var fingerprint: String? {
        guard let tool = toolURL else { return nil }
        return Self.fingerprint(ofToolURL: tool)
    }

    public var isValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let components = URLComponents(string: trimmed) else { return false }
        guard let scheme = components.scheme?.lowercased() else { return false }
        guard ["socks5", "socks5h", "http", "https"].contains(scheme) else { return false }
        return components.host != nil && components.port != nil
    }
}
