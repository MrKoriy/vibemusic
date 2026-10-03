import Foundation
import os

/// Быстрый путь резолва YouTube: один-два запроса к InnerTube player API.
///
/// Полный пайплайн yt-dlp (веб-страница ~1.5 МБ + player API + пробы m3u8)
/// занимает 15–25 с даже на VPN. InnerTube-клиент VISIONOS — тот же, что
/// yt-dlp использует по умолчанию, — не требует JS-плеера и PO-токена
/// (REQUIRE_JS_PLAYER: False, без GVS-политики в _base.py 2026.08.19),
/// поэтому его запрос можно повторить напрямую и получить тот же itag 140.
///
/// При любой ошибке (проверка на ботов, live, возрастное ограничение,
/// нет m4a-форматов) метод бросает ошибку — резолв откатывается на yt-dlp.
enum InnertubeClient {
    static let playerEndpoint = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"

    /// UA из конфигурации клиента VISIONOS в yt-dlp (важен для прохождения проверки).
    static let visionosUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static let requestTimeout: TimeInterval = 12
    /// Аудио AAC (audio/mp4), которое AVPlayer играет без перекодирования.
    /// Порядок = приоритет: 140 (128k), 139 (48k), 256/258 (high quality).
    static let preferredItags: [Int] = [140, 139, 256, 258]

    private static let logger = Logger(subsystem: "com.vibemusic.app", category: "innertube")

    /// Отладка в stderr при VIBEMUSIC_DEBUG (см. StreamHub.log).
    private static let debugEnabled = ProcessInfo.processInfo.environment["VIBEMUSIC_DEBUG"] != nil

    static func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let t = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)
        FileHandle.standardError.write(Data(String(format: "[it  %7.2f] %@\n", t, message()).utf8))
    }

    /// Visitor data переживает один ответ LOGIN_REQUIRED и переиспользуется:
    /// первый резолв за запуск — два запроса, остальные — один.
    private static let visitorLock = NSLock()
    nonisolated(unsafe) private static var _visitorData: String?

    static var visitorData: String? {
        visitorLock.lock()
        defer { visitorLock.unlock() }
        return _visitorData
    }

    static func storeVisitorData(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        visitorLock.lock()
        _visitorData = value
        visitorLock.unlock()
    }

    // MARK: - Публичный API

    /// Прямая ссылка на аудиопоток. Приоритет:
    /// 1. HLS audio-playlist (прямой маршрут) — AVPlayer играет HLS нативно,
    ///    включая live-трансляции. Прогрессивные itag-URL YouTube сейчас
    ///    отдаёт как fMP4-сегменты (ftyp+moov+sidx+moof…) — AVPlayer не может
    ///    играть их как прогрессивную загрузку: качает весь файл молча.
    /// 2. Прогрессивный itag-URL с проверкой данных (для маршрута через прокси,
    ///    куда AVPlayer не умеет ходить, и как запасной вариант).
    static func audioStream(for videoID: String, proxy: String?) async throws -> URL {
        let started = Date()
        let response = try await fetchPlayer(videoID: videoID, proxy: proxy)

        guard response.playability == "OK" else {
            debugLog("player not OK: \(response.playability ?? "?") — \(response.reason ?? "")")
            logger.log("player not OK: \(response.playability ?? "?", privacy: .public) \(response.reason ?? "", privacy: .public)")
            throw InnertubeError.notPlayable
        }

        if proxy == nil, let master = response.hlsManifestURL {
            do {
                let playlist = try await resolveAudioPlaylist(master: master, proxy: nil)
                debugLog("HLS audio playlist за \(String(format: "%.2f", Date().timeIntervalSince(started)))с")
                return playlist
            } catch {
                debugLog("HLS недоступен (\(error)), пробую прогрессивный URL")
            }
        }

        guard let url = response.bestAudioURL else {
            if response.isLive {
                debugLog("live без HLS — отдаю yt-dlp")
                throw InnertubeError.liveStream
            }
            debugLog("нет m4a-форматов — отдаю yt-dlp")
            throw InnertubeError.noAudioFormat
        }

        let probeStart = Date()
        try await probe(url: url, proxy: proxy)
        debugLog("resolved за \(String(format: "%.2f", Date().timeIntervalSince(started)))с (probe \(String(format: "%.2f", Date().timeIntervalSince(probeStart)))с) \(url.host ?? "?")")
        return url
    }

    /// Достаёт из мастер-манифеста HLS плейлист «только аудио» (itag 234 = 140,
    /// 233 = 139, иначе первый TYPE=AUDIO). GET манифеста сам по себе
    /// проверяет живость ссылки.
    static func resolveAudioPlaylist(master: URL, proxy: String?) async throws -> URL {
        let body: Data
        if let proxy {
            let response = try await CurlFetcher.fetch(
                url: master,
                headers: ["User-Agent": LocalStream.userAgent],
                proxy: proxy,
                timeout: requestTimeout
            )
            guard (200...299).contains(response.status) else {
                throw InnertubeError.transport("manifest http \(response.status)")
            }
            body = response.body
        } else {
            var request = URLRequest(url: master)
            request.setValue(LocalStream.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = requestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw InnertubeError.transport("manifest http \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            body = data
        }
        guard let text = String(data: body, encoding: .utf8),
              let playlist = Self.audioPlaylist(fromManifest: text) else {
            throw InnertubeError.transport("no audio playlist in manifest")
        }
        return playlist
    }

    /// Парсинг мастер-манифеста: строки #EXT-X-MEDIA c TYPE=AUDIO содержат
    /// URI="…" — абсолютный плейлист одного аудиопотока. Чистая функция.
    static func audioPlaylist(fromManifest manifest: String) -> URL? {
        var fallback: URL?
        for line in manifest.split(separator: "\n") {
            let lineText = String(line)
            guard lineText.hasPrefix("#EXT-X-MEDIA"),
                  lineText.contains("TYPE=AUDIO"),
                  let uriRange = lineText.range(of: "URI=\"") else { continue }
            let afterURI = lineText[uriRange.upperBound...]
            guard let close = afterURI.firstIndex(of: "\"") else { continue }
            let uri = String(afterURI[..<close])
            guard let url = URL(string: uri) else { continue }
            if uri.contains("itag/234") { return url }
            if uri.contains("itag/233"), fallback == nil { fallback = url }
            if fallback == nil { fallback = url }
        }
        return fallback
    }

    /// Метаданные одного видео для импорта: 1–2 запроса вместо yt-dlp -J.
    static func metadata(for videoID: String, proxy: String?) async throws -> Track {
        let response = try await fetchPlayer(videoID: videoID, proxy: proxy)
        guard response.playability == "OK", let title = response.title, !title.isEmpty else {
            throw InnertubeError.notPlayable
        }
        let duration = response.lengthSeconds.flatMap { $0 > 0 ? $0 : nil }
        return Track(
            id: videoID,
            title: title,
            channel: response.author,
            duration: duration,
            liveFlag: response.isLive ? true : nil,
            source: .user
        )
    }

    /// Синхронная обёртка для легаси-вызовов (CLI, importTracks).
    static func metadataSync(for videoID: String, proxy: String?) -> Track? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = try? await metadata(for: videoID, proxy: proxy)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Track?
        var value: Track? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - Транспорт

    private static func fetchPlayer(videoID: String, proxy: String?) async throws -> PlayerResponse {
        let started = Date()
        let knownVisitor = visitorData
        let first = try await postPlayer(videoID: videoID, visitorData: knownVisitor, proxy: proxy)
        if first.playability == "OK" {
            debugLog("player OK за \(String(format: "%.2f", Date().timeIntervalSince(started)))с (visitor: \(knownVisitor != nil))")
            return first
        }

        // «Sign in to confirm you're not a bot»: visitor data из ответа
        // разблокирует повторный запрос (см. yt-dlp generate_api_headers).
        if knownVisitor == nil, let fresh = first.visitorData {
            debugLog("LOGIN_REQUIRED, повторяю с visitor data")
            storeVisitorData(fresh)
            let second = try await postPlayer(videoID: videoID, visitorData: fresh, proxy: proxy)
            debugLog("повторный player: \(second.playability ?? "?") за \(String(format: "%.2f", Date().timeIntervalSince(started)))с")
            return second
        }
        return first
    }

    static func postPlayer(videoID: String, visitorData: String?, proxy: String?) async throws -> PlayerResponse {
        let body = playerBody(videoID: videoID, visitorData: visitorData)
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "User-Agent": visionosUserAgent,
            "X-YouTube-Client-Name": "101",
            "X-YouTube-Client-Version": "1.02",
        ]
        if let visitorData, !visitorData.isEmpty {
            headers["X-Goog-Visitor-Id"] = visitorData
        }
        guard let endpoint = URL(string: playerEndpoint) else {
            throw InnertubeError.transport("bad endpoint")
        }
        let data: Data
        if let proxy {
            let response = try await CurlFetcher.fetch(
                url: endpoint,
                method: .post(body: body, contentType: "application/json"),
                headers: headers,
                proxy: proxy,
                timeout: requestTimeout
            )
            data = response.body
        } else {
            data = try await urlSessionPost(url: endpoint, body: body, headers: headers, timeout: requestTimeout)
        }
        guard let parsed = PlayerResponse.parse(data: data) else {
            throw InnertubeError.transport("bad json")
        }
        return parsed
    }

    private static func urlSessionPost(
        url: URL,
        body: Data,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw InnertubeError.transport("http \(code)")
        }
        return data
    }

    /// Живая проверка ссылки: Range 0-2047 тем же маршрутом, что и резолв.
    /// Заодно смотрит структуру MP4: прогрессивный файл обязан содержать
    /// mdat раньше любых sidx/moof — иначе это fMP4/DASH-сегмент, который
    /// AVPlayer не играет как прогрессивную загрузку.
    private static func probe(url: URL, proxy: String?) async throws {
        let head: Data
        if let proxy {
            let response = try await CurlFetcher.fetch(
                url: url,
                range: (0, 2047),
                proxy: proxy,
                timeout: requestTimeout
            )
            guard (200...299).contains(response.status) else {
                throw InnertubeError.transport("probe http \(response.status)")
            }
            head = response.body
        } else {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            request.setValue(LocalStream.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = requestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw InnertubeError.transport("probe http \(code)")
            }
            head = data
        }
        if isFragmentedMP4(head) {
            throw InnertubeError.fragmentedMP4
        }
    }

    /// Разбор цепочки top-level боксов: true, если до первого mdat встретился
    /// sidx или moof (признак fMP4/DASH-сегмента).
    static func isFragmentedMP4(_ head: Data) -> Bool {
        var offset = 0
        while offset + 8 <= head.count {
            let size = head.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | Int($1) }
            let type = String(data: head.subdata(in: offset + 4..<offset + 8), encoding: .ascii) ?? ""
            switch type {
            case "moof", "sidx":
                return true
            case "mdat":
                return false
            default:
                break
            }
            if size < 8 { break }
            offset += size
        }
        return false
    }

    // MARK: - Тело запроса (чистые функции, тестируются напрямую)

    static func playerBody(videoID: String, visitorData: String?) -> Data {
        let client: [String: Any] = [
            "clientName": "VISIONOS",
            "clientVersion": "1.02",
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "userAgent": visionosUserAgent,
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
            "hl": "en",
            "gl": "US",
        ]
        var context: [String: Any] = ["client": client]
        if let visitorData, !visitorData.isEmpty {
            context["visitorData"] = visitorData
        }
        // порядок ключей стабилен: JSONSerialization сортирует ключи,
        // YouTube на порядок не завязан.
        return (try? JSONSerialization.data(withJSONObject: ["context": context, "videoId": videoID])) ?? Data()
    }

    /// ID видео из разрешённой YouTube-ссылки или сырой 11-символьный ID.
    static func extractVideoID(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVideoID(trimmed) { return trimmed }
        guard let components = URLComponents(string: trimmed) else { return nil }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
           isVideoID(v) {
            return v
        }
        if components.host == "youtu.be" {
            let path = components.path.dropFirst()
            if isVideoID(String(path)) { return String(path) }
        }
        // ссылки shorts/youtube.com/e/… не поддерживаем — yt-dlp разберётся сам
        return nil
    }

    static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

enum InnertubeError: Error, CustomStringConvertible {
    case notPlayable
    case liveStream
    case noAudioFormat
    case fragmentedMP4
    case transport(String)

    var description: String {
        switch self {
        case .notPlayable: return "innertube: not playable"
        case .liveStream: return "innertube: live"
        case .noAudioFormat: return "innertube: no m4a format"
        case .fragmentedMP4: return "innertube: fMP4 (не прогрессивный)"
        case .transport(let message): return "innertube: \(message)"
        }
    }
}

// MARK: - Разбор ответа

/// Чистый разбор JSON-ответа /youtubei/v1/player — без сети, тестируется фикстурами.
struct PlayerResponse: Equatable, Sendable {
    struct AdaptiveFormat: Equatable, Sendable {
        let itag: Int
        let url: URL?
        let contentLength: Int64?
        let averageBitrate: Int?

        var isAudioMP4: Bool {
            // mimeType вида "audio/mp4; codecs=\"mp4a.40.2\""
            mimeType?.hasPrefix("audio/mp4") ?? false
        }

        fileprivate let mimeType: String?
        fileprivate let ciphered: Bool
    }

    let playability: String?
    let reason: String?
    let visitorData: String?
    let title: String?
    let author: String?
    let lengthSeconds: Double?
    let isLive: Bool
    let hlsManifestURL: URL?
    let formats: [AdaptiveFormat]

    /// Лучшая прямая (не шифрованная) ссылка из предпочитаемых itag.
    var bestAudioURL: URL? {
        let byItag = Dictionary(formats.filter { !$0.ciphered && $0.url != nil }.map { ($0.itag, $0) },
                                uniquingKeysWith: { first, _ in first })
        for itag in InnertubeClient.preferredItags {
            if let format = byItag[itag], format.url != nil {
                return format.url
            }
        }
        return nil
    }

    static func parse(data: Data) -> PlayerResponse? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let playabilityDict = json["playabilityStatus"] as? [String: Any]
        let videoDetails = json["videoDetails"] as? [String: Any]
        let streamingData = json["streamingData"] as? [String: Any]

        let rawFormats = ((streamingData?["adaptiveFormats"] as? [[String: Any]]) ?? [])
            + ((streamingData?["formats"] as? [[String: Any]]) ?? [])
        let formats = rawFormats.compactMap { raw -> AdaptiveFormat? in
            guard let itag = raw["itag"] as? Int else { return nil }
            let urlString = raw["url"] as? String
            // формат с cipher/signature без url недоступен напрямую
            let ciphered = raw["cipher"] != nil || raw["signatureCipher"] != nil || urlString == nil
            return AdaptiveFormat(
                itag: itag,
                url: urlString.flatMap(URL.init(string:)),
                contentLength: (raw["contentLength"] as? String).flatMap(Int64.init),
                averageBitrate: raw["averageBitrate"] as? Int,
                mimeType: raw["mimeType"] as? String,
                ciphered: ciphered
            )
        }

        return PlayerResponse(
            playability: playabilityDict?["status"] as? String,
            reason: playabilityDict?["reason"] as? String,
            visitorData: (json["responseContext"] as? [String: Any])?["visitorData"] as? String,
            title: videoDetails?["title"] as? String,
            author: videoDetails?["author"] as? String,
            lengthSeconds: (videoDetails?["lengthSeconds"] as? String).flatMap(Double.init),
            isLive: (videoDetails?["isLiveContent"] as? Bool) == true,
            hlsManifestURL: (streamingData?["hlsManifestUrl"] as? String).flatMap(URL.init(string:)),
            formats: formats
        )
    }
}
