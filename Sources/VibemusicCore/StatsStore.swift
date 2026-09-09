import Foundation

public struct SessionRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var minutes: Int
    public var mode: SessionMode

    public init(id: UUID = UUID(), date: Date = Date(), minutes: Int, mode: SessionMode) {
        self.id = id
        self.date = date
        self.minutes = minutes
        self.mode = mode
    }
}

@MainActor
public final class StatsStore: ObservableObject {
    @Published public private(set) var records: [SessionRecord] = [] {
        didSet { persist() }
    }
    @Published public private(set) var lastLoadError: String?

    private let fileURL: URL

    public init(directory: URL? = nil) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("stats.json")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = base.appendingPathComponent("Vibemusic", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("stats.json")
        }
        load()
    }

    public func record(minutes: Int, mode: SessionMode, date: Date = Date()) {
        guard minutes > 0 else { return }
        records.append(SessionRecord(date: date, minutes: minutes, mode: mode))
    }

    public func reset() {
        records = []
    }

    public var totalMinutes: Int { records.reduce(0) { $0 + $1.minutes } }
    public var sessionCount: Int { records.count }
    public var todayMinutes: Int { minutes(on: Date()) }

    public func minutes(on day: Date) -> Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        return records
            .filter { cal.startOfDay(for: $0.date) == start }
            .reduce(0) { $0 + $1.minutes }
    }

    public func lastDays(_ count: Int) -> [(day: Date, minutes: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: today).map { ($0, minutes(on: $0)) }
        }
    }

    public var currentStreak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if minutes(on: day) == 0 {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while minutes(on: day) > 0 {
            streak += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    private func load() {
        switch PersistenceUtil.load([SessionRecord].self, from: fileURL) {
        case .loaded(let loaded):
            records = loaded
        case .missing:
            break
        case .corrupted:
            records = []
            lastLoadError = "Файл статистики повреждён; создана резервная копия"
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records),
              (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        lastLoadError = nil
    }
}
