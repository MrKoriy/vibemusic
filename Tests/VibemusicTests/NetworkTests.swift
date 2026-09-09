import Foundation
import Testing
@testable import VibemusicCore

// MARK: - ProxyConfig

@Test func proxyConfigMigratesLegacyKeys() throws {
    let suiteName = "NetworkTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: "proxyEnabled")
    defaults.set("socks5://user:pass@1.2.3.4:1080", forKey: "proxyURL")

    let config = ProxyConfig.load(defaults: defaults)

    #expect(config.enabled)
    #expect(config.url == "socks5://user:pass@1.2.3.4:1080")
    #expect(config.mode == .auto)
    #expect(defaults.object(forKey: "com.vibemusic.proxy.enabled") as? Bool == true)
    #expect(defaults.string(forKey: "com.vibemusic.proxy.url") == "socks5://user:pass@1.2.3.4:1080")
    #expect(defaults.object(forKey: "proxyEnabled") == nil)
    #expect(defaults.object(forKey: "proxyURL") == nil)
}

@Test func proxyConfigMigrationSkippedWhenNewKeyExists() throws {
    let suiteName = "NetworkTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: "com.vibemusic.proxy.enabled")
    defaults.set("socks5://new.example.com:1080", forKey: "com.vibemusic.proxy.url")
    defaults.set("socks5://old.example.com:1080", forKey: "proxyURL")

    let config = ProxyConfig.load(defaults: defaults)

    #expect(config.url == "socks5://new.example.com:1080")
    #expect(defaults.string(forKey: "com.vibemusic.proxy.url") == "socks5://new.example.com:1080")
}

@Test func proxyConfigEmptyOrInvalidURLDisablesProxy() throws {
    let suiteName = "NetworkTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Свежие настройки: URL пустой → прокси выключен.
    let fresh = ProxyConfig.load(defaults: defaults)
    #expect(fresh.url == "")
    #expect(!fresh.enabled)
    #expect(fresh.toolURL == nil)

    // Включён, но URL пустой.
    defaults.set(true, forKey: "com.vibemusic.proxy.enabled")
    defaults.set("", forKey: "com.vibemusic.proxy.url")
    let empty = ProxyConfig.load(defaults: defaults)
    #expect(!empty.enabled)
    #expect(empty.toolURL == nil)

    // Включён, но URL невалидный.
    defaults.set("not a url at all", forKey: "com.vibemusic.proxy.url")
    let invalid = ProxyConfig.load(defaults: defaults)
    #expect(!invalid.enabled)
    #expect(invalid.toolURL == nil)
}

@Test func proxyConfigToolURLModeMatrix() {
    let valid = "socks5://user:pass@1.2.3.4:1080"
    let normalized = "socks5h://user:pass@1.2.3.4:1080"

    // auto — прежняя семантика (дефолт).
    #expect(ProxyConfig(enabled: true, url: valid, mode: .auto).toolURL == normalized)
    #expect(ProxyConfig(enabled: true, url: valid).toolURL == normalized)
    #expect(ProxyConfig(enabled: false, url: valid, mode: .auto).toolURL == nil)
    #expect(ProxyConfig(enabled: true, url: "", mode: .auto).toolURL == nil)

    // forced — только прокси, флаг enabled не важен, URL обязан быть валидным.
    #expect(ProxyConfig(enabled: true, url: valid, mode: .forced).toolURL == normalized)
    #expect(ProxyConfig(enabled: false, url: valid, mode: .forced).toolURL == normalized)
    #expect(ProxyConfig(enabled: true, url: "", mode: .forced).toolURL == nil)
    #expect(ProxyConfig(enabled: true, url: "nonsense", mode: .forced).toolURL == nil)
    #expect(ProxyConfig(enabled: true, url: "socks5://1.2.3.4", mode: .forced).toolURL == nil)

    // direct — всегда мимо прокси.
    #expect(ProxyConfig(enabled: true, url: valid, mode: .direct).toolURL == nil)
    #expect(ProxyConfig(enabled: true, url: "", mode: .direct).toolURL == nil)
}

@Test func proxyConfigModeRoundTrip() throws {
    let suiteName = "NetworkTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let config = ProxyConfig(enabled: true, url: "socks5://1.2.3.4:1080", mode: .forced)
    config.save(defaults: defaults)

    let loaded = ProxyConfig.load(defaults: defaults)
    #expect(loaded.mode == .forced)
    #expect(loaded.enabled)
    #expect(loaded.toolURL == "socks5h://1.2.3.4:1080")

    // Неизвестное значение режима деградирует в auto.
    defaults.set("bogus", forKey: "com.vibemusic.proxy.mode")
    #expect(ProxyConfig.load(defaults: defaults).mode == .auto)
}

@Test func proxyConfigFingerprintHidesCredentials() {
    let config = ProxyConfig(enabled: true, url: "socks5://user:secret@1.2.3.4:1080", mode: .auto)
    #expect(config.fingerprint == "socks5h://1.2.3.4:1080")
    #expect(config.fingerprint?.contains("user") == false)
    #expect(config.fingerprint?.contains("secret") == false)

    let httpConfig = ProxyConfig(enabled: false, url: "http://user:pass@proxy.example.com:8080", mode: .forced)
    #expect(httpConfig.fingerprint == "http://proxy.example.com:8080")

    // Без эффективного прокси отпечатка нет.
    #expect(ProxyConfig(enabled: false, url: "socks5://1.2.3.4:1080", mode: .auto).fingerprint == nil)
    #expect(ProxyConfig(enabled: true, url: "socks5://1.2.3.4:1080", mode: .direct).fingerprint == nil)
    #expect(ProxyConfig(enabled: true, url: "nonsense", mode: .auto).fingerprint == nil)
}

// MARK: - StreamURLCache

@Test func streamCacheFingerprintRouting() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = StreamURLCache(directory: dir)
    let url = try #require(URL(string: "https://media.example.com/videoplayback/audio.track"))

    cache.set(videoID: "abc12345678", url: url, viaProxy: true, fingerprint: "socks5h://1.2.3.4:1080")

    // Существующий get без маршрута по-прежнему валиден.
    #expect(cache.get(videoID: "abc12345678") != nil)
    // Совпавший отпечаток — попадание.
    #expect(cache.get(videoID: "abc12345678", route: "socks5h://1.2.3.4:1080") != nil)

    // Несовпадение → nil и запись удалена (в т.ч. для маршрута без проверки).
    #expect(cache.get(videoID: "abc12345678", route: "socks5h://5.6.7.8:1080") == nil)
    #expect(cache.get(videoID: "abc12345678") == nil)
    #expect(cache.get(videoID: "abc12345678", route: "socks5h://1.2.3.4:1080") == nil)

    // Запись без отпечатка (прямой маршрут): nil-маршрут совпадает, прокси — нет.
    cache.set(videoID: "def12345678", url: url, viaProxy: false, fingerprint: nil)
    #expect(cache.get(videoID: "def12345678", route: nil) != nil)
    #expect(cache.get(videoID: "def12345678", route: "socks5h://1.2.3.4:1080") == nil)
    #expect(cache.get(videoID: "def12345678") == nil)
}

@Test func streamCacheBackupsCorruptFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("stream_cache.json")
    try Data("this is not json {{{".utf8).write(to: fileURL)

    let cache = StreamURLCache(directory: dir)

    // Кэш стартует пустым.
    #expect(cache.get(videoID: "abc12345678") == nil)

    // Битый файл уехал в бэкап .corrupt-*, оригинал удалён.
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files.contains { $0.hasPrefix("stream_cache.corrupt-") && $0.hasSuffix(".json") })
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

// MARK: - YTResolver

@Test func manifestURLDetection() throws {
    #expect(YTResolver.isManifestURL(try #require(URL(string: "https://example.com/media/playlist/index.m3u8"))))
    #expect(YTResolver.isManifestURL(try #require(URL(string: "https://example.com/media/dash/stream.mpd"))))
    #expect(YTResolver.isManifestURL(try #require(URL(string: "https://example.com/media/playlist/index.m3u8?token=abc&sig=123"))))

    // ".m3u8" в query-параметре — не манифест.
    #expect(!YTResolver.isManifestURL(try #require(URL(string: "https://example.com/media/video?id=track.m3u8"))))
    #expect(!YTResolver.isManifestURL(try #require(URL(string: "https://example.com/media/audiotrack.m4a"))))

    #expect(YTResolver.slowResolveThreshold == 12)
}
