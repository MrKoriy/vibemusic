import Foundation

public final class StreamURLCache: @unchecked Sendable {
    public static let shared = StreamURLCache()

    struct Entry: Codable, Sendable {
        let urlString: String
        let viaProxy: Bool
        let expiresAt: TimeInterval

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

    public func set(videoID: String, url: URL, viaProxy: Bool) {
        let expiry = Self.parseExpiry(from: url) ?? (Date().timeIntervalSince1970 + 14400)
        let entry = Entry(urlString: url.absoluteString, viaProxy: viaProxy, expiresAt: expiry)

        lock.lock()
        entries[videoID] = entry
        lock.unlock()

        saveAsync()
    }

    private static func parseExpiry(from url: URL) -> TimeInterval? {
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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        lock.lock()
        let now = Date().timeIntervalSince1970
        entries = decoded.filter { $0.value.expiresAt > now + 600 }
        lock.unlock()
    }

    private func snapshotData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let valid = entries.filter { $0.value.expiresAt > now + 600 }
        return try? JSONEncoder().encode(valid)
    }

    private func saveAsync() {
        guard let data = snapshotData() else { return }
        let target = self.fileURL
        Task.detached(priority: .utility) {
            try? data.write(to: target, options: .atomic)
        }
    }
}
