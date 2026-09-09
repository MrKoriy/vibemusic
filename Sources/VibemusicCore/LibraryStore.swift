import Foundation

@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var curated: [MusicCategory]
    @Published public var userTracks: [Track] {
        didSet { persistUserTracks() }
    }
    @Published public private(set) var lastLoadError: String?

    public static let myCategoryID = "my"

    private let directory: URL

    public init(directory: URL? = nil) {
        let resolved: URL
        if let directory {
            resolved = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            resolved = base.appendingPathComponent("Vibemusic", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        let userFile = resolved.appendingPathComponent("user_tracks.json")

        curated = Self.loadCurated()
        userTracks = []
        lastLoadError = nil
        self.directory = resolved

        switch PersistenceUtil.load([Track].self, from: userFile) {
        case .loaded(let tracks):
            userTracks = tracks
        case .missing:
            break
        case .corrupted:
            lastLoadError = "Файл пользовательских треков повреждён; создана резервная копия"
        }
    }

    private static func loadCurated() -> [MusicCategory] {
        guard let url = Bundle.module.url(forResource: "library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(LibraryDoc.self, from: data) else { return [] }
        return doc.categories
    }

    private var userFileURL: URL {
        directory.appendingPathComponent("user_tracks.json")
    }

    private func persistUserTracks() {
        guard let data = try? JSONEncoder().encode(userTracks),
              (try? data.write(to: userFileURL, options: .atomic)) != nil else { return }
        lastLoadError = nil
    }

    public var userCategory: MusicCategory {
        MusicCategory(id: Self.myCategoryID, title: "Мои ссылки", mode: .focus, defaultMinutes: 50, tracks: userTracks)
    }

    public var allCategories: [MusicCategory] { curated + [userCategory] }

    public func category(id: String) -> MusicCategory? {
        allCategories.first { $0.id == id }
    }

    public func addUserTracks(_ tracks: [Track]) {
        var seen = Set(userTracks.map(\.id))
        var unique: [Track] = []
        for track in tracks where !seen.contains(track.id) {
            seen.insert(track.id)
            unique.append(track)
        }
        guard !unique.isEmpty else { return }
        userTracks.append(contentsOf: unique)
    }

    public func removeUserTrack(id: String) {
        userTracks.removeAll { $0.id == id }
    }
}
