import Foundation

/// Конфигурация SOCKS5-прокси. Хранится в UserDefaults, редактируется в настройках.
/// Прокси используется и для резолва ссылок (yt-dlp), и для загрузки аудио (curl),
/// причём оба шага всегда идут одним маршрутом: googlevideo привязывает ссылку к IP.
public struct ProxyConfig: Equatable, Sendable {
    public var enabled: Bool
    public var url: String

    /// Прокси задаётся в настройках приложения (не хардкодим секреты в репозитории).
    public static let embeddedDefaultURL = ""

    static let enabledKey = "proxyEnabled"
    static let urlKey = "proxyURL"

    public init(enabled: Bool, url: String) {
        self.enabled = enabled
        self.url = url
    }

    public static func load(defaults: UserDefaults = .standard) -> ProxyConfig {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let url = defaults.string(forKey: urlKey) ?? embeddedDefaultURL
        return ProxyConfig(enabled: enabled, url: url)
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(url, forKey: Self.urlKey)
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

    /// Готовый URL для инструментов, nil — если прокси выключен или пустой.
    public var toolURL: String? {
        guard enabled else { return nil }
        return Self.toolURL(from: url)
    }

    public var isValid: Bool {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)) else { return false }
        guard let scheme = components.scheme?.lowercased() else { return false }
        guard ["socks5", "socks5h", "http", "https"].contains(scheme) else { return false }
        return components.host != nil && components.port != nil
    }
}
