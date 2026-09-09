import Foundation
import Testing
@testable import VibemusicCore

// MARK: - Изоляция LibraryStore (C-2)

@MainActor @Test func libraryStoreIsolatedToDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let realURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vibemusic", isDirectory: true)
        .appendingPathComponent("user_tracks.json")
    let realBefore = try? Data(contentsOf: realURL)

    let store = LibraryStore(directory: dir)
    let unique = "iso" + UUID().uuidString.prefix(8)
    store.addUserTracks([Track(id: unique, title: "Isolated")])
    #expect(store.userTracks.map(\.id) == [unique])

    let reloaded = LibraryStore(directory: dir)
    #expect(reloaded.userTracks.map(\.id) == [unique])
    #expect(reloaded.lastLoadError == nil)

    reloaded.removeUserTrack(id: unique)
    #expect(reloaded.userTracks.isEmpty)
    #expect(LibraryStore(directory: dir).userTracks.isEmpty)

    let realAfter = try? Data(contentsOf: realURL)
    #expect(realBefore == realAfter)
    if let data = realAfter, let text = String(data: data, encoding: .utf8) {
        #expect(!text.contains(unique))
    }
}

// MARK: - Бэкап битых JSON (C-1)

@MainActor @Test func libraryStoreBacksUpCorruptedUserTracks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("user_tracks.json")
    try Data("это не JSON {{{".utf8).write(to: fileURL)

    let store = LibraryStore(directory: dir)

    #expect(store.userTracks.isEmpty)
    #expect(store.lastLoadError != nil)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("user_tracks.corrupt-") && $0.hasSuffix(".json") }
    #expect(backups.count == 1)

    store.addUserTracks([Track(id: "fix00000001", title: "Fix")])
    #expect(store.lastLoadError == nil)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@MainActor @Test func statsStoreBacksUpCorruptedFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("stats.json")
    try Data("мусор вместо статистики".utf8).write(to: fileURL)

    let stats = StatsStore(directory: dir)

    #expect(stats.records.isEmpty)
    #expect(stats.totalMinutes == 0)
    #expect(stats.sessionCount == 0)
    #expect(stats.lastLoadError != nil)
    let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("stats.corrupt-") && $0.hasSuffix(".json") }
    #expect(backups.count == 1)

    stats.record(minutes: 5, mode: .focus)
    #expect(stats.lastLoadError == nil)
}

// MARK: - Дедупликация батча (C-3)

@MainActor @Test func addUserTracksDeduplicatesWithinBatchAndAgainstExisting() {
    let a = Track(id: "dedup00001", title: "A")
    let b = Track(id: "dedup00002", title: "B")

    let empty = LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    empty.addUserTracks([a, a, b])
    #expect(empty.userTracks.map(\.id) == ["dedup00001", "dedup00002"])

    let seeded = LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    seeded.addUserTracks([a])
    seeded.addUserTracks([a, a, b])
    #expect(seeded.userTracks.map(\.id) == ["dedup00001", "dedup00002"])
}

// MARK: - Трёхстатусная модель трека (E-6)

@Test func trackStatusMatrix() {
    #expect(Track(id: "st00000001", title: "Curated live", source: .curated).status == .live)
    #expect(Track(id: "st00000002", title: "User unknown").status == .unknown)
    #expect(Track(id: "st00000003", title: "Explicit live", liveFlag: true).status == .live)
    #expect(Track(id: "st00000004", title: "VOD", duration: 120).status == .vod)
    #expect(Track(id: "st00000005", title: "Explicit not live", liveFlag: false, source: .user).status == .unknown)
}

@Test func trackDecodesLiveFlagKeys() throws {
    let live = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"lf00000001","title":"Radio","is_live":true}"#.utf8))
    #expect(live.liveFlag == true)
    #expect(live.isLive)

    let status = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"lf00000002","title":"Radio","live_status":"is_live"}"#.utf8))
    #expect(status.liveFlag == true)
    #expect(status.isLive)

    let vod = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"lf00000003","title":"Show","is_live":false,"duration":300}"#.utf8))
    #expect(vod.liveFlag == false)
    #expect(vod.status == .vod)

    let absent = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"lf00000004","title":"No keys"}"#.utf8))
    #expect(absent.liveFlag == nil)
    #expect(absent.source == .user)
    #expect(absent.status == .unknown)
}

@Test func trackRoundTripWithNewFields() throws {
    let live = Track(id: "rt00000001", title: "Live stream", channel: "Chan", liveFlag: true, source: .curated)
    let decodedLive = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(live))
    #expect(decodedLive == live)
    #expect(decodedLive.liveFlag == true)
    #expect(decodedLive.source == .curated)
    #expect(decodedLive.isLive)

    let vod = Track(id: "rt00000002", title: "Mix", channel: "Chan", duration: 7200, liveFlag: false, source: .user)
    let decodedVod = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(vod))
    #expect(decodedVod == vod)
    #expect(decodedVod.status == .vod)
}

@MainActor @Test func libraryStoreMarksCuratedAndUserSources() {
    let store = LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(!store.curated.isEmpty)
    #expect(store.curated.allSatisfy { $0.tracks.allSatisfy { $0.source == .curated } })

    let curatedLive = store.curated.flatMap(\.tracks).first { $0.duration == nil }
    #expect(curatedLive?.isLive == true)

    store.addUserTracks([Track(id: "src00000001", title: "User link")])
    #expect(store.userTracks.allSatisfy { $0.source == .user })
    #expect(store.userCategory.tracks.allSatisfy { $0.source == .user })
}
