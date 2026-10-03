import Foundation
import Testing
@testable import VibemusicCore

// MARK: - Защита от подстановки аргументов yt-dlp

@Test func sanitizedSourceAcceptsVideoIDAndYouTubeLinks() throws {
    #expect(try YTResolver.sanitizedSource("dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(try YTResolver.sanitizedSource("  https://youtu.be/dQw4w9WgXcQ \n") == "https://youtu.be/dQw4w9WgXcQ")
    let playlist = "https://www.youtube.com/playlist?list=PL1234567890"
    #expect(try YTResolver.sanitizedSource(playlist) == playlist)
    let music = "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD1"
    #expect(try YTResolver.sanitizedSource(music) == music)
}

@Test func sanitizedSourceRejectsOptionsAndForeignHosts() {
    let rejected = [
        "--exec=open -a Calculator",
        "-o /tmp/x",
        "--",
        "https://evil.example.com/watch?v=dQw4w9WgXcQ",
        "file:///etc/passwd",
        "https://youtube.com.evil.example/watch?v=x",
        "",
    ]
    for value in rejected {
        #expect(throws: ResolverError.self) { try YTResolver.sanitizedSource(value) }
    }
}

// MARK: - Валидация ответа upstream для чанка

@Test func parseRangeStartReadsContentRange() {
    #expect(LocalStream.parseRangeStart("bytes 100-199/1000") == 100)
    #expect(LocalStream.parseRangeStart("bytes 0-0/1") == 0)
    #expect(LocalStream.parseRangeStart("bytes */1000") == nil)
    #expect(LocalStream.parseRangeStart("garbage") == nil)
}

@Test func chunkPayloadAccepts206WithMatchingStart() {
    let body = Data(repeating: 7, count: 10)
    let payload = LocalStream.chunkPayload(
        status: 206, contentRange: "bytes 1048576-1048585/5000000", body: body, lower: 1_048_576
    )
    #expect(payload == body)
}

@Test func chunkPayloadRejects206WithForeignStart() {
    let payload = LocalStream.chunkPayload(
        status: 206, contentRange: "bytes 0-9/5000000", body: Data(repeating: 1, count: 10), lower: 1_048_576
    )
    #expect(payload == nil)
}

@Test func chunkPayloadSlicesFullBodyWhenRangeIgnored() {
    // Upstream вернул 200 с файлом целиком: берём байты с нужного смещения.
    let chunk = Int(LocalStream.chunkSize)
    var body = Data(repeating: 0, count: chunk)
    body.append(Data(repeating: 9, count: 100))
    let payload = LocalStream.chunkPayload(status: 200, contentRange: nil, body: body, lower: Int64(chunk))
    #expect(payload == Data(repeating: 9, count: 100))
}

@Test func chunkPayloadRejectsErrorsAndEmptyBodies() {
    #expect(LocalStream.chunkPayload(status: 403, contentRange: nil, body: Data([1]), lower: 0) == nil)
    #expect(LocalStream.chunkPayload(status: 206, contentRange: nil, body: Data(), lower: 0) == nil)
    #expect(LocalStream.chunkPayload(status: 200, contentRange: nil, body: Data([1, 2]), lower: 1_048_576) == nil)
}

// MARK: - autoNext не крутит очередь бесконечно

@Suite(.serialized)
@MainActor
struct PlayerFailureLimitTests {
    @Test func autoNextStopsAfterConsecutiveFailures() async throws {
        let player = PlayerCore()
        let counter = CallCounter()
        player.resolve = { _, _ in
            counter.increment()
            throw URLError(.badURL)
        }
        let tracks = (0..<3).map { Track(id: "vid0000000\($0)yy", title: "Track \($0)") }
        player.play(
            category: MusicCategory(id: "t", title: "Т", mode: .focus, defaultMinutes: 25, tracks: tracks),
            shuffle: false
        )
        // Лимит для очереди из 3 — 4 неудачи: 0 / 1.5 / 3.0 / 4.5 с.
        try await Task.sleep(nanoseconds: 7_000_000_000)

        #expect(player.needsRetry == true)
        #expect(counter.value == 4)
        player.reset()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
