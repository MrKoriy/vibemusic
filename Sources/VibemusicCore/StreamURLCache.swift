import Foundation

public final class StreamURLCache: @unchecked Sendable {
    public static let shared = StreamURLCache()

    struct Entry: Codable, Sendable {
        let urlString: String
        let viaProxy: Bool
        let expiresAt: TimeInterval
        let proxyFingerprint: String?

        var isValid: Bool {
            expiresAt > Date().timeIntervalSince1970 + 600
        }

        var url: URL? { URL(string: urlString) }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("Vibemusic", isDirectory: true)
        }
        self.fileURL = dir.appendingPathComponent("stream_cache.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    public func get(videoID: String) -> (url: URL, viaProxy: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[videoID] else { return nil }
        if entry.isValid, let url = entry.url {
            return (url, entry.viaProxy)
        }
        entries.removeValue(forKey: videoID)
        return nil
    }

    /// Получение записи с проверкой маршрута: ссылка googlevideo привязана к IP,
    /// поэтому при несовпадении отпечатка прокси запись считается протухшей —
    /// возвращается nil, а запись удаляется.
    public func get(videoID: String, route fingerprint: String?) -> (url: URL, viaProxy: Bool)? {
        var hit: (url: URL, viaProxy: Bool)?
        var removed = false
        lock.lock()
        if let entry = entries[videoID] {
            if entry.isValid, let url = entry.url, entry.proxyFingerprint == fingerprint {
                hit = (url, entry.viaProxy)
            } else {
                entries.removeValue(forKey: videoID)
                removed = true
            }
        }
        lock.unlock()
        if removed { saveAsync() }
        return hit
    }

    public func set(videoID: String, url: URL, viaProxy: Bool, fingerprint: String? = nil) {
        let expiry = Self.parseExpiry(from: url) ?? (Date().timeIntervalSince1970 + 14400)
        let entry = Entry(
            urlString: url.absoluteString,
            viaProxy: viaProxy,
            expiresAt: expiry,
            proxyFingerprint: fingerprint
        )

        lock.lock()
        entries[videoID] = entry
        lock.unlock()

        saveAsync()
    }

    static func parseExpiry(from url: URL) -> TimeInterval? {
        let str = url.absoluteString
        if let range = str.range(of: "expire/([0-9]{9,12})", options: .regularExpression) {
            let sub = str[range].dropFirst(7)
            return TimeInterval(sub)
        }
        if let range = str.range(of: "expire=([0-9]{9,12})", options: .regularExpression) {
            let sub = str[range].dropFirst(7)
            return TimeInterval(sub)
        }
        return nil
    }

    private func load() {
        // Битый JSON не затираем молча: PersistenceUtil уводит файл в бэкап
        // .corrupt-*, кэш стартует пустым (аудит C-4).
        switch PersistenceUtil.load([String: Entry].self, from: fileURL) {
        case .loaded(let decoded):
            lock.lock()
            let now = Date().timeIntervalSince1970
            entries = decoded.filter { $0.value.expiresAt > now + 600 }
            lock.unlock()
        case .missing, .corrupted:
            lock.lock()
            entries = [:]
            lock.unlock()
        }
    }

    private func snapshotData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let valid = entries.filter { $0.value.expiresAt > now + 600 }
        return try? JSONEncoder().encode(valid)
    }

    private let saveQueue = DispatchQueue(label: "vibemusic.cache.save", qos: .utility)

    private func saveAsync() {
        guard let data = snapshotData() else { return }
        let target = self.fileURL
        saveQueue.async {
            try? data.write(to: target, options: .atomic)
        }
    }
}
