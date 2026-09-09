import Foundation
import Testing
@testable import VibemusicCore

@MainActor @Test func libraryDecodes() throws {
    let json = """
    {
      "version": 1,
      "categories": [
        {
          "id": "work",
          "title": "Работа",
          "mode": "focus",
          "defaultMinutes": 50,
          "tracks": [
            { "id": "abc12345678", "title": "deep house", "channel": "MM House", "duration": 8990 },
            { "id": "def12345678", "title": "live radio", "channel": "Lofi Girl", "duration": null }
          ]
        }
      ]
    }
    """
    let doc = try JSONDecoder().decode(LibraryDoc.self, from: Data(json.utf8))
    #expect(doc.version == 1)
    let category = try #require(doc.categories.first)
    #expect(category.mode == .focus)
    #expect(category.defaultMinutes == 50)
    #expect(category.tracks.count == 2)
    #expect(category.tracks[0].duration == 8990)
    #expect(category.tracks[1].duration == nil)
    #expect(category.tracks[1].isLive)
    #expect(category.tracks[0].durationLabel == "2 ч 29 м")
}

@MainActor @Test func trackRoundTrip() throws {
    let track = Track(id: "xyz12345678", title: "Test", channel: "Chan", duration: 120)
    let data = try JSONEncoder().encode(track)
    let decoded = try JSONDecoder().decode(Track.self, from: data)
    #expect(decoded == track)
}

@MainActor @Test func userCategoryBuilds() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LibraryStore(directory: dir)
    store.addUserTracks([Track(id: "aaa11111111", title: "One")])
    store.addUserTracks([Track(id: "aaa11111111", title: "Duplicate")])
    let my = store.userCategory
    #expect(my.id == LibraryStore.myCategoryID)
    #expect(my.tracks.count == 1)
    #expect(store.allCategories.count == store.curated.count + 1)
    store.removeUserTrack(id: "aaa11111111")
    #expect(store.userCategory.tracks.isEmpty)
}

@MainActor @Test func statsRecordingAndStreak() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stats = StatsStore(directory: dir)
    let cal = Calendar.current
    let now = Date()

    stats.record(minutes: 30, mode: .focus, date: now)
    stats.record(minutes: 25, mode: .meditate, date: now)
    #expect(stats.todayMinutes == 55)
    #expect(stats.totalMinutes == 55)
    #expect(stats.sessionCount == 2)
    #expect(stats.currentStreak == 1)

    let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
    stats.record(minutes: 50, mode: .focus, date: yesterday)
    #expect(stats.currentStreak == 2)

    let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: now)!
    stats.record(minutes: 10, mode: .sleep, date: twoDaysAgo)
    #expect(stats.currentStreak == 3)

    let days = stats.lastDays(7)
    #expect(days.count == 7)
    #expect(days.last?.minutes == 55)
    #expect(days[days.count - 2].minutes == 50)

    stats.record(minutes: 0, mode: .focus)
    #expect(stats.sessionCount == 4)

    stats.reset()
    #expect(stats.totalMinutes == 0)
    #expect(stats.currentStreak == 0)
}

@MainActor @Test func statsPersistAcrossInstances() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = StatsStore(directory: dir)
    first.record(minutes: 42, mode: .focus)
    let second = StatsStore(directory: dir)
    #expect(second.totalMinutes == 42)
    #expect(second.sessionCount == 1)
}

@Test func proxyConfigToolURL() {
    var config = ProxyConfig(enabled: false, url: "socks5://u:p@1.2.3.4:44441")
    #expect(config.toolURL == nil)

    config.enabled = true
    #expect(config.toolURL == "socks5h://u:p@1.2.3.4:44441")

    config.url = "   "
    #expect(config.toolURL == nil)

    config.url = "socks5h://user:pass@proxy.example.com:1080"
    #expect(config.toolURL == "socks5h://user:pass@proxy.example.com:1080")

    config.url = "http://user:pass@proxy.example.com:8080"
    #expect(config.toolURL == "http://user:pass@proxy.example.com:8080")

    config.url = "  socks5://u:p@1.2.3.4:44441  "
    #expect(config.toolURL == "socks5h://u:p@1.2.3.4:44441")
}

@Test func proxyConfigValidation() {
    #expect(ProxyConfig(enabled: true, url: "socks5://u:p@1.2.3.4:1080").isValid)
    #expect(ProxyConfig(enabled: true, url: "socks5h://u:p@host.ru:1080").isValid)
    #expect(ProxyConfig(enabled: true, url: "http://u:p@1.2.3.4:8080").isValid)
    #expect(!ProxyConfig(enabled: true, url: "nonsense").isValid)
    #expect(!ProxyConfig(enabled: true, url: "ftp://1.2.3.4:21").isValid)
    #expect(!ProxyConfig(enabled: true, url: "socks5://1.2.3.4").isValid)
}

@Test func curlHeaderParsingIgnoresRedirectBlock() {
    let dump = "HTTP/1.1 302 Found\r\n"
        + "Location: https://other.host/videoplayback\r\n"
        + "Content-Type: text/html\r\n\r\n"
        + "HTTP/1.1 206 Partial Content\r\n"
        + "Content-Range: bytes 0-1/145492064\r\n"
        + "Content-Type: audio/mp4\r\n\r\n"
    let parsed = CurlFetcher.parse(headerDump: dump)
    #expect(parsed.status == 206)
    #expect(parsed.headers["content-range"] == "bytes 0-1/145492064")
    #expect(parsed.headers["content-type"] == "audio/mp4")
    #expect(parsed.headers["location"] == nil)

    let single = "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n"
    let parsedSingle = CurlFetcher.parse(headerDump: single)
    #expect(parsedSingle.status == 200)
    #expect(parsedSingle.headers["content-length"] == "42")

    let empty = CurlFetcher.parse(headerDump: "")
    #expect(empty.status == 0)
    #expect(empty.headers.isEmpty)
}

@Test func curlErrorMapping() {
    if case URLError.timedOut = CurlFetcher.mapError(exitCode: 28) {} else {
        Issue.record("expected timedOut for exit 28")
    }
    if case URLError.cannotConnectToHost = CurlFetcher.mapError(exitCode: 7) {} else {
        Issue.record("expected cannotConnectToHost for exit 7")
    }
    if case URLError.cannotConnectToHost = CurlFetcher.mapError(exitCode: 97) {} else {
        Issue.record("expected cannotConnectToHost for exit 97 (SOCKS)")
    }
    if case URLError.badServerResponse = CurlFetcher.mapError(exitCode: 22) {} else {
        Issue.record("expected badServerResponse for exit 22")
    }
}
