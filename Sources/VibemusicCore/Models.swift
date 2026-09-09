import Foundation

public enum SessionMode: String, Codable, Sendable {
    case focus, meditate, sleep, wake
}

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var channel: String?
    public var duration: Double?

    public init(id: String, title: String, channel: String? = nil, duration: Double? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.duration = duration
    }

    public var url: URL { URL(string: "https://www.youtube.com/watch?v=" + id) ?? URL(fileURLWithPath: "/") }
    public var isLive: Bool { duration == nil || duration == 0 }

    public var durationLabel: String? {
        guard let d = duration, d > 0 else { return nil }
        let total = Int(d)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) ч \(m) м" }
        if m > 0 { return "\(m) м" }
        return "\(total) с"
    }

    enum CodingKeys: String, CodingKey {
        case id, title, channel, duration, uploader
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "Без названия"
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel))
            ?? (try? c.decodeIfPresent(String.self, forKey: .uploader))
        if let d = try? c.decodeIfPresent(Double.self, forKey: .duration), d.isFinite {
            duration = d
        } else {
            duration = nil
        }
        if let u = try? c.decodeIfPresent(String.self, forKey: .uploader), channel == nil {
            channel = u
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(channel, forKey: .channel)
        try c.encodeIfPresent(duration, forKey: .duration)
    }
}

public struct MusicCategory: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var mode: SessionMode
    public var defaultMinutes: Int
    public var tracks: [Track]

    public init(id: String, title: String, mode: SessionMode, defaultMinutes: Int, tracks: [Track]) {
        self.id = id
        self.title = title
        self.mode = mode
        self.defaultMinutes = defaultMinutes
        self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey {
        case id, title, mode, defaultMinutes, tracks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        mode = (try? c.decode(SessionMode.self, forKey: .mode)) ?? .focus
        defaultMinutes = (try? c.decode(Int.self, forKey: .defaultMinutes)) ?? 25
        tracks = (try? c.decode([Track].self, forKey: .tracks)) ?? []
    }
}

public struct LibraryDoc: Codable, Sendable {
    public var version: Int
    public var categories: [MusicCategory]
}
