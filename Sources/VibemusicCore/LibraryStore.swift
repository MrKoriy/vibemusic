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

        let curatedResult = Self.loadCurated()
        curated = curatedResult.categories
        curatedLoadError = curatedResult.error
        userTracks = []
        lastLoadError = curatedResult.error
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

    /// Error from loading bundled library.json, surfaced to UI if non-nil.
    public private(set) var curatedLoadError: String?

    private static func loadCurated() -> (categories: [MusicCategory], error: String?) {
        guard let url = curatedLibraryURL() else {
            return ([], "Библиотека не найдена в bundle (Vibemusic_VibemusicCore.bundle отсутствует)")
        }
        guard let data = try? Data(contentsOf: url) else {
            return ([], "Не удалось прочитать библиотеку")
        }
        do {
            let doc = try JSONDecoder().decode(LibraryDoc.self, from: data)
            return (doc.categories, nil)
        } catch {
            return ([], "Библиотека повреждена: \(error.localizedDescription)")
        }
    }

    /// Безопасная замена Bundle.module: тот крэшит fatalError если .bundle не найден
    /// (см. Translated Report: NSBundle.module + LibraryStore.loadCurated -> SIGTRAP).
    /// Повторяем кандидаты из сгенерированного resource_bundle_accessor.swift, но возвращаем nil.
    private static func curatedLibraryURL() -> URL? {
        let bundleName = "Vibemusic_VibemusicCore"
        let fm = FileManager.default
        var overrideURLs: [URL] = []
        if let p = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ??
                  ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            overrideURLs.append(URL(fileURLWithPath: p))
            // Если путь указывает прямо на .bundle — пробуем его содержимое
            if p.hasSuffix(".bundle"), let b = Bundle(url: URL(fileURLWithPath: p)),
               let u = b.url(forResource: "library", withExtension: "json") { return u }
            let direct = URL(fileURLWithPath: p).appendingPathComponent("library.json")
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        let candidates: [URL?] = overrideURLs + [
            Bundle.main.resourceURL,
            Bundle(for: LibraryStore.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        for cand in candidates {
            guard let c = cand else { continue }
            let bundleURL = c.appendingPathComponent(bundleName + ".bundle")
            if fm.fileExists(atPath: bundleURL.path), let b = Bundle(url: bundleURL),
               let u = b.url(forResource: "library", withExtension: "json") { return u }
            // На случай если library.json положили прямо в Resources без .bundle (fallback)
            let direct = c.appendingPathComponent("library.json")
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        // Последние попытки — напрямую через Bundle API (покрывает swift test)
        if let u = Bundle(for: LibraryStore.self).url(forResource: "library", withExtension: "json") { return u }
        if let u = Bundle.main.url(forResource: "library", withExtension: "json") { return u }
        return nil
    }

    private var userFileURL: URL {
        directory.appendingPathComponent("user_tracks.json")
    }

    private func persistUserTracks() {
        do {
            let data = try JSONEncoder().encode(userTracks)
            try data.write(to: userFileURL, options: .atomic)
            lastLoadError = nil
        } catch {
            lastLoadError = "Не удалось сохранить: \(error.localizedDescription)"
        }
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
