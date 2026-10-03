import Foundation

public enum SessionMode: String, Codable, Sendable {
    case focus, meditate, sleep, wake
}

public enum TrackStatus: String, Codable, Sendable {
    case live, vod, unknown
}

public enum TrackSource: String, Codable, Sendable {
    case curated, user
}

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var channel: String?
    public var duration: Double?
    public var liveFlag: Bool?
    public var source: TrackSource

    public init(id: String, title: String, channel: String? = nil, duration: Double? = nil, liveFlag: Bool? = nil, source: TrackSource = .user) {
        self.id = id
        self.title = title
        self.channel = channel
        self.duration = duration
        self.liveFlag = liveFlag
        self.source = source
    }

    public var url: URL? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return URL(string: "https://www.youtube.com/watch?v=" + encoded)
    }
    /// Legacy non-optional accessor — falls back to file root only if encoding fails (should never happen).
    public var urlValue: URL { url ?? URL(fileURLWithPath: "/") }

    public var status: TrackStatus {
        if liveFlag == true { return .live }
        if let d = duration, d > 0 { return .vod }
        if source == .curated, duration == nil { return .live }
        return .unknown
    }

    public var isLive: Bool { status == .live }

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
        case source
        case isLive = "is_live"
        case liveStatus = "live_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = try? c.decode(String.self, forKey: .id), !decodedID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Track.id is required and must be non-empty")
        }
        id = decodedID
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
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .isLive) {
            liveFlag = flag
        } else if let liveStatus = try? c.decodeIfPresent(String.self, forKey: .liveStatus), liveStatus == "is_live" {
            liveFlag = true
        } else {
            liveFlag = nil
        }
        source = (try? c.decode(TrackSource.self, forKey: .source)) ?? .user
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(channel, forKey: .channel)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(liveFlag, forKey: .isLive)
        try c.encode(source, forKey: .source)
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
        guard let decodedCatID = try? c.decode(String.self, forKey: .id), !decodedCatID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "MusicCategory.id is required and must be non-empty")
        }
        id = decodedCatID
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        mode = (try? c.decode(SessionMode.self, forKey: .mode)) ?? .focus
        defaultMinutes = (try? c.decode(Int.self, forKey: .defaultMinutes)) ?? 25
        var decodedTracks = (try? c.decode([Track].self, forKey: .tracks)) ?? []
        for index in decodedTracks.indices {
            decodedTracks[index].source = .curated
        }
        tracks = decodedTracks
    }
}

public struct LibraryDoc: Codable, Sendable {
    public var version: Int
    public var categories: [MusicCategory]
}
