import Foundation
import Testing
@testable import VibemusicCore

// MARK: - Креды прокси не попадают в argv

@Test func ytDlpProxyConfigQuotesForShlex() {
    let contents = YTResolver.proxyConfigContents(proxy: "socks5h://u:p'a#ss@h:1080")
    #expect(contents == "--proxy 'socks5h://u:p'\"'\"'a#ss@h:1080'\n")
    #expect(YTResolver.proxyConfigContents(proxy: "socks5h://u:p@h:1080\n--exec=x") == nil)
    #expect(YTResolver.proxyConfigContents(proxy: "") == nil)
}

@Test func curlProxyConfigLineEscapes() {
    #expect(CurlFetcher.configLine(proxy: "socks5h://u:p@h:1080") == "proxy = \"socks5h://u:p@h:1080\"\n")
    #expect(CurlFetcher.configLine(proxy: "socks5h://u:p\"\\@h:1") == "proxy = \"socks5h://u:p\\\"\\\\@h:1\"\n")
    #expect(CurlFetcher.configLine(proxy: "socks5h://h:1\rurl = x") == nil)
}

// MARK: - Адрес прокси в хранилище секретов

@Test func proxyURLMigratesFromDefaultsToSecretStore() throws {
    let suiteName = "SecretsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = InMemorySecretStore()

    defaults.set(true, forKey: "com.vibemusic.proxy.enabled")
    defaults.set("socks5://user:pass@1.2.3.4:1080", forKey: "com.vibemusic.proxy.url")

    let config = ProxyConfig.load(defaults: defaults, secrets: secrets)
    #expect(config.url == "socks5://user:pass@1.2.3.4:1080")
    #expect(config.enabled)
    #expect(defaults.string(forKey: "com.vibemusic.proxy.url") == nil)
    #expect(secrets.read("com.vibemusic.proxy.url") == "socks5://user:pass@1.2.3.4:1080")
}

@Test func proxySaveWritesSecretOutsideDefaults() throws {
    let suiteName = "SecretsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = InMemorySecretStore()

    ProxyConfig(enabled: true, url: "socks5://u:p@5.6.7.8:1080", mode: .forced).save(defaults: defaults, secrets: secrets)
    #expect(defaults.string(forKey: "com.vibemusic.proxy.url") == nil)
    #expect(secrets.read("com.vibemusic.proxy.url") == "socks5://u:p@5.6.7.8:1080")

    let loaded = ProxyConfig.load(defaults: defaults, secrets: secrets)
    #expect(loaded.mode == .forced)
    #expect(loaded.toolURL == "socks5h://u:p@5.6.7.8:1080")
}

@Test func proxySaveFallsBackToDefaultsWhenSecretStoreFails() throws {
    let suiteName = "SecretsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = InMemorySecretStore()
    secrets.failWrites = true

    ProxyConfig(enabled: true, url: "socks5://u:p@5.6.7.8:1080").save(defaults: defaults, secrets: secrets)
    #expect(defaults.string(forKey: "com.vibemusic.proxy.url") == "socks5://u:p@5.6.7.8:1080")
    #expect(ProxyConfig.load(defaults: defaults, secrets: secrets).url == "socks5://u:p@5.6.7.8:1080")
}

// MARK: - Обновление протухшей ссылки googlevideo

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

@Test func sameMediaComparesItagAndLength() {
    let a = URL(string: "https://r1.googlevideo.com/videoplayback?itag=140&clen=1000&expire=1")!
    let b = URL(string: "https://r2.googlevideo.com/videoplayback?itag=140&clen=1000&expire=2")!
    let otherFormat = URL(string: "https://r2.googlevideo.com/videoplayback?itag=251&clen=900")!
    #expect(LocalStream.isSameMedia(a, b))
    #expect(!LocalStream.isSameMedia(a, otherFormat))
    #expect(LocalStream.isSameMedia(a, URL(string: "https://example.com/a.m4a")!))
}

@Test func concurrentRefreshesShareOneResolve() async throws {
    let old = URL(string: "https://r1.googlevideo.com/videoplayback?itag=140&expire=1")!
    let fresh = URL(string: "https://r2.googlevideo.com/videoplayback?itag=140&expire=9999999999")!
    let counter = RefreshCounter()
    let stream = LocalStream(upstream: old, port: 1, refresher: {
        _ = counter.increment()
        try await Task.sleep(nanoseconds: 200_000_000)
        return fresh
    })

    async let first = stream.refreshUpstream(replacing: old)
    async let second = stream.refreshUpstream(replacing: old)
    let results = try await [first, second]

    #expect(results == [fresh, fresh])
    #expect(counter.value == 1)
    #expect(stream.upstream == fresh)
    // Запрос со старой ссылкой после обновления сразу получает новую.
    #expect(try await stream.refreshUpstream(replacing: old) == fresh)
    #expect(counter.value == 1)
    // Повторный 403 сразу после обновления — не крутим резолв по кругу.
    await #expect(throws: LocalStream.UpstreamHTTPError.self) {
        try await stream.refreshUpstream(replacing: fresh)
    }
    #expect(counter.value == 1)
}

@Test func refreshRejectsDifferentFormat() async throws {
    let old = URL(string: "https://r1.googlevideo.com/videoplayback?itag=140&expire=1")!
    let stream = LocalStream(upstream: old, port: 1, refresher: {
        URL(string: "https://r2.googlevideo.com/videoplayback?itag=251&expire=9999999999")!
    })
    await #expect(throws: LocalStream.UpstreamHTTPError.self) {
        try await stream.refreshUpstream(replacing: old)
    }
    #expect(stream.upstream == old)
}

@Test func refreshWithoutRefresherFails() async {
    let old = URL(string: "https://r1.googlevideo.com/videoplayback?expire=1")!
    let stream = LocalStream(upstream: old, port: 1)
    await #expect(throws: LocalStream.UpstreamHTTPError.self) {
        try await stream.refreshUpstream(replacing: old)
    }
}

@Test func usableUpstreamRefreshesOnlyNearExpiry() async throws {
    let now = Date()
    let soon = Int(now.timeIntervalSince1970) + 30
    let later = Int(now.timeIntervalSince1970) + 3600
    let fresh = URL(string: "https://r2.googlevideo.com/videoplayback?expire=\(later + 20000)")!
    let counter = RefreshCounter()

    let farStream = LocalStream(
        upstream: URL(string: "https://r1.googlevideo.com/videoplayback?expire=\(later)")!,
        port: 1,
        refresher: { _ = counter.increment(); return fresh }
    )
    _ = try await farStream.usableUpstream(now: now)
    #expect(counter.value == 0)

    let soonStream = LocalStream(
        upstream: URL(string: "https://r1.googlevideo.com/videoplayback?expire=\(soon)")!,
        port: 1,
        refresher: { _ = counter.increment(); return fresh }
    )
    #expect(try await soonStream.usableUpstream(now: now) == fresh)
    #expect(counter.value == 1)
}
