import Foundation

/// Утилиты персистентности: загрузка JSON с защитой от потери данных (аудит C-1).
/// Повреждённый файл НЕ затирается молча — перемещается в бэкап,
/// а стор получает диагноз для показа пользователю.
public enum PersistenceUtil {
    public enum LoadOutcome<T: Decodable> {
        case loaded(T)
        case missing
        case corrupted(String)
    }

    /// Декодирует JSON из файла. При повреждении перемещает битый файл
    /// в `<имя>.corrupt-<yyyyMMdd-HHmmss>.json` и возвращает `.corrupted`.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> LoadOutcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else {
            return .corrupted(backupCorrupt(fileURL: url, reason: "файл не читается"))
        }
        do {
            return .loaded(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .corrupted(backupCorrupt(fileURL: url, reason: error.localizedDescription))
        }
    }

    @discardableResult
    private static func backupCorrupt(fileURL: URL, reason: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        // Если даже переместить не удалось — файл останется на месте
        // и будет перезаписан при следующем сохранении; диагноз всё равно возвращаем.
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        return reason
    }
}
