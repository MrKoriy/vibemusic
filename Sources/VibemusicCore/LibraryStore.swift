import Foundation

@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var curated: [MusicCategory]
    @Published public var userTracks: [Track] {
        didSet { persistUserTracks() }
    }

    public static let myCategoryID = "my"

    public init() {
        curated = Self.loadCurated()
        userTracks = Self.loadUserTracks()
    }

    private static func loadCurated() -> [MusicCategory] {
        guard let url = Bundle.module.url(forResource: "library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(LibraryDoc.self, from: data) else { return [] }
        return doc.categories
    }

    private static var userFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Vibemusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_tracks.json")
    }

    private static func loadUserTracks() -> [Track] {
        guard let data = try? Data(contentsOf: userFileURL),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        return tracks
    }

    private func persistUserTracks() {
        guard let data = try? JSONEncoder().encode(userTracks) else { return }
        try? data.write(to: Self.userFileURL, options: .atomic)
    }

    public var userCategory: MusicCategory {
        MusicCategory(id: Self.myCategoryID, title: "Мои ссылки", mode: .focus, defaultMinutes: 50, tracks: userTracks)
    }

    public var allCategories: [MusicCategory] { curated + [userCategory] }

    public func category(id: String) -> MusicCategory? {
        allCategories.first { $0.id == id }
    }

    public func addUserTracks(_ tracks: [Track]) {
        let existing = Set(userTracks.map(\.id))
        userTracks.append(contentsOf: tracks.filter { !existing.contains($0.id) })
    }

    public func removeUserTrack(id: String) {
        userTracks.removeAll { $0.id == id }
    }
}
