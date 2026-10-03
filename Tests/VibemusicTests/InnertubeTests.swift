import Foundation
import Testing
@testable import VibemusicCore

// MARK: - Разбор ответа InnerTube (чистые функции, без сети)

private func fixture(_ json: String) -> Data {
    Data(json.utf8)
}

@Test func innertubeParsesPlayerResponse() throws {
    let data = fixture("""
    {
      "playabilityStatus": {"status": "OK"},
      "responseContext": {"visitorData": "Cgtabc%3D%3D"},
      "videoDetails": {
        "videoId": "u-PeF3SfY5w",
        "title": "Lane 8 Summer 2024 Mixtape",
        "author": "This Never Happened",
        "lengthSeconds": "11109",
        "isLiveContent": false
      },
      "streamingData": {
        "adaptiveFormats": [
          {"itag": 249, "mimeType": "audio/webm; codecs=\\"opus\\"", "cipher": "s=xxx"},
          {"itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "url": "https://rr4.googlevideo.com/videoplayback?itag=140&clen=179798996", "contentLength": "179798996", "averageBitrate": 129000},
          {"itag": 139, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "url": "https://rr4.googlevideo.com/videoplayback?itag=139"}
        ]
      }
    }
    """)

    let response = try #require(PlayerResponse.parse(data: data))

    #expect(response.playability == "OK")
    #expect(response.visitorData == "Cgtabc%3D%3D")
    #expect(response.title == "Lane 8 Summer 2024 Mixtape")
    #expect(response.author == "This Never Happened")
    #expect(response.lengthSeconds == 11109)
    #expect(response.isLive == false)
    #expect(response.formats.count == 3)
}

@Test func innertubePicksPreferredItagAndSkipsCiphered() throws {
    let data = fixture("""
    {
      "playabilityStatus": {"status": "OK"},
      "streamingData": {
        "adaptiveFormats": [
          {"itag": 249, "mimeType": "audio/webm", "cipher": "s=xxx"},
          {"itag": 258, "mimeType": "audio/mp4", "url": "https://gv.com/a?itag=258"},
          {"itag": 140, "mimeType": "audio/mp4", "url": "https://gv.com/a?itag=140"}
        ]
      }
    }
    """)
    let response = try #require(PlayerResponse.parse(data: data))
    // 140 в приоритете перед 258, шифрованный 249 не берём.
    #expect(response.bestAudioURL?.absoluteString.contains("itag=140") == true)
}

@Test func innertubeFallsBackToLowestItag() throws {
    let data = fixture("""
    {
      "playabilityStatus": {"status": "OK"},
      "streamingData": {
        "adaptiveFormats": [
          {"itag": 139, "mimeType": "audio/mp4", "url": "https://gv.com/a?itag=139"}
        ]
      }
    }
    """)
    let response = try #require(PlayerResponse.parse(data: data))
    #expect(response.bestAudioURL != nil)
}

@Test func innertubeNoUsableFormats() throws {
    let data = fixture("""
    {
      "playabilityStatus": {"status": "OK"},
      "streamingData": {
        "adaptiveFormats": [
          {"itag": 251, "mimeType": "audio/webm", "url": "https://gv.com/a?itag=251"}
        ]
      }
    }
    """)
    let response = try #require(PlayerResponse.parse(data: data))
    #expect(response.bestAudioURL == nil)
}

@Test func innertubeLoginRequiredAndVisitorData() throws {
    let data = fixture("""
    {
      "playabilityStatus": {"status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"},
      "responseContext": {"visitorData": "Cgvisitor%3D%3D"}
    }
    """)
    let response = try #require(PlayerResponse.parse(data: data))
    #expect(response.playability == "LOGIN_REQUIRED")
    #expect(response.visitorData == "Cgvisitor%3D%3D")
    #expect(response.bestAudioURL == nil)
}

@Test func innertubeGarbageInputReturnsNil() {
    #expect(PlayerResponse.parse(data: Data("not json".utf8)) == nil)
    #expect(PlayerResponse.parse(data: Data("[]".utf8)) == nil)
}

// MARK: - HLS

@Test func innertubeParsesHLSManifestURL() throws {
    let data = fixture("""
    {
      "playabilityStatus": {"status": "OK"},
      "streamingData": {
        "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1791082456/itag/234/index.m3u8"
      }
    }
    """)
    let response = try #require(PlayerResponse.parse(data: data))
    #expect(response.hlsManifestURL?.absoluteString.contains("hls_variant") == true)
}

@Test func innertubeAudioPlaylistPicksPreferredItag() throws {
    let manifest = """
    #EXTM3U
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:URI="https://gv.com/playlist/itag/233/index.m3u8",TYPE=AUDIO,GROUP-ID="233"
    #EXT-X-MEDIA:URI="https://gv.com/playlist/itag/234/index.m3u8",TYPE=AUDIO,GROUP-ID="234"
    #EXT-X-STREAM-INF:BANDWIDTH=143208,AUDIO="233"
    https://gv.com/playlist/itag/229/index.m3u8
    """
    // 234 (аудио 128k) в приоритете.
    #expect(InnertubeClient.audioPlaylist(fromManifest: manifest)?.absoluteString.contains("itag/234") == true)

    let onlyLow = """
    #EXTM3U
    #EXT-X-MEDIA:URI="https://gv.com/playlist/itag/233/index.m3u8",TYPE=AUDIO,GROUP-ID="233"
    """
    #expect(InnertubeClient.audioPlaylist(fromManifest: onlyLow)?.absoluteString.contains("itag/233") == true)

    // Только видео-варианты без AUDIO — плейлиста нет.
    #expect(InnertubeClient.audioPlaylist(fromManifest: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://gv.com/v.m3u8") == nil)
}

// MARK: - fMP4-детект (защита от DASH-сегментов)

private func mp4File(_ boxes: [(type: String, size: Int)]) -> Data {
    var data = Data()
    for box in boxes {
        var size = UInt32(box.size).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(Data(box.type.utf8))
        data.append(Data(repeating: 0xAB, count: max(0, box.size - 8)))
    }
    return data
}

@Test func fragmentedMP4Detection() {
    // ftyp + moov + sidx → fMP4/DASH-сегмент.
    let fragmented = mp4File([("ftyp", 24), ("moov", 699), ("sidx", 13388)])
    #expect(InnertubeClient.isFragmentedMP4(fragmented) == true)

    // ftyp + moov + mdat → честный прогрессивный MP4.
    let progressive = mp4File([("ftyp", 24), ("moov", 699), ("mdat", 1024)])
    #expect(InnertubeClient.isFragmentedMP4(progressive) == false)

    // ftyp + moov + moof → фрагментированный.
    let moofFirst = mp4File([("ftyp", 24), ("moov", 699), ("moof", 512)])
    #expect(InnertubeClient.isFragmentedMP4(moofFirst) == true)

    // Пустые/битые данные — не детектим как фрагментированные.
    #expect(InnertubeClient.isFragmentedMP4(Data()) == false)
    #expect(InnertubeClient.isFragmentedMP4(Data([0, 0, 0])) == false)
}

// MARK: - Тело запроса

@Test func innertubePlayerBodyStructure() throws {
    let body = InnertubeClient.playerBody(videoID: "abcdefghijk", visitorData: nil)
    let json = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
    #expect(json["videoId"] as? String == "abcdefghijk")
    let context = try #require(json["context"] as? [String: Any])
    let client = try #require(context["client"] as? [String: Any])
    #expect(client["clientName"] as? String == "VISIONOS")
    #expect(client["clientVersion"] as? String == "1.02")
    #expect(context["visitorData"] == nil)

    let bodyWithVisitor = InnertubeClient.playerBody(videoID: "abcdefghijk", visitorData: "vd")
    let json2 = try #require((try? JSONSerialization.jsonObject(with: bodyWithVisitor)) as? [String: Any])
    let context2 = try #require(json2["context"] as? [String: Any])
    #expect(context2["visitorData"] as? String == "vd")
}

// MARK: - Извлечение ID видео

@Test func innertubeExtractVideoID() throws {
    #expect(InnertubeClient.extractVideoID(from: "u-PeF3SfY5w") == "u-PeF3SfY5w")
    #expect(InnertubeClient.extractVideoID(from: "  https://www.youtube.com/watch?v=u-PeF3SfY5w&t=1 ") == "u-PeF3SfY5w")
    #expect(InnertubeClient.extractVideoID(from: "https://youtu.be/u-PeF3SfY5w?si=x") == "u-PeF3SfY5w")
    #expect(InnertubeClient.extractVideoID(from: "https://www.youtube.com/watch?v=short") == nil)
    #expect(InnertubeClient.extractVideoID(from: "https://music.youtube.com/watch?v=u-PeF3SfY5w") == "u-PeF3SfY5w")
    #expect(InnertubeClient.extractVideoID(from: "https://www.youtube.com/shorts/abcdef") == nil)
}

// MARK: - Curl POST через конфиг (аргументы собираются без секретов в argv)

@Test func curlFetcherConfigLineEscapesQuotes() {
    let line = CurlFetcher.configLine(proxy: "socks5h://user:pa\\ss\"x@h:1080")
    #expect(line?.contains("socks5h://user:pa\\\\ss\\\"x@h:1080") == true)
}
