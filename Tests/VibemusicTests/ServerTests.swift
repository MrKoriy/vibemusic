import Foundation
import Network
import Testing
@testable import VibemusicCore

// MARK: - parseRange

@Test func parseRangeAcceptsBoundedAndOpenEnded() {
    #expect(HTTPConnectionHandler.parseRange("bytes=0-99") == .offset(start: 0, end: 99))
    #expect(HTTPConnectionHandler.parseRange("bytes=100-") == .offset(start: 100, end: nil))
    #expect(HTTPConnectionHandler.parseRange("BYTES=0-99") == .offset(start: 0, end: 99))
    #expect(HTTPConnectionHandler.parseRange("bytes= 8 - 99 ") == .offset(start: 8, end: 99))
    #expect(HTTPConnectionHandler.parseRange("bytes=1048575-2097151") == .offset(start: 1_048_575, end: 2_097_151))
}

@Test func parseRangeAcceptsSuffix() {
    #expect(HTTPConnectionHandler.parseRange("bytes=-500") == .suffix(length: 500))
    #expect(HTTPConnectionHandler.parseRange("bytes=-1") == .suffix(length: 1))
    #expect(HTTPConnectionHandler.parseRange("bytes= -500 ") == .suffix(length: 500))
}

@Test func parseRangeRejectsGarbage() {
    #expect(HTTPConnectionHandler.parseRange("bytes=abc-def") == nil)
    #expect(HTTPConnectionHandler.parseRange("items=0-99") == nil)
    #expect(HTTPConnectionHandler.parseRange("") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=-") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=-0") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=-abc") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=0-1,5-9") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=-500-600") == nil)
    #expect(HTTPConnectionHandler.parseRange("bytes=x-99") == nil)
}

// MARK: - Разрешение диапазона по total

@Test func suffixRangeResolvesAgainstTotal() {
    #expect(HTTPConnectionHandler.resolvedBounds(.suffix(length: 500), total: 1000) == (500, 999))
    #expect(HTTPConnectionHandler.resolvedBounds(.suffix(length: 1000), total: 1000) == (0, 999))
    #expect(HTTPConnectionHandler.resolvedBounds(.suffix(length: 1500), total: 1000) == (0, 999))
}

@Test func offsetRangeResolvesAgainstTotal() {
    #expect(HTTPConnectionHandler.resolvedBounds(nil, total: 1000) == (0, 999))
    #expect(HTTPConnectionHandler.resolvedBounds(.offset(start: 100, end: nil), total: 1000) == (100, 999))
    #expect(HTTPConnectionHandler.resolvedBounds(.offset(start: 100, end: 200), total: 1000) == (100, 200))
    #expect(HTTPConnectionHandler.resolvedBounds(.offset(start: 900, end: 5000), total: 1000) == (900, 999))
}

// MARK: - Content-Type

@Test func localStreamContentTypeDefaultAndFirstWins() {
    let stream = LocalStream(upstream: URL(string: "https://example.invalid/audio.m4a")!, port: 1)
    #expect(stream.resolvedContentType() == "audio/mp4")
    stream.recordContentType("audio/webm")
    #expect(stream.resolvedContentType() == "audio/webm")
    stream.recordContentType("audio/mpeg")
    #expect(stream.resolvedContentType() == "audio/webm")
    stream.recordContentType(nil)
    stream.recordContentType("   ")
    #expect(stream.resolvedContentType() == "audio/webm")
}

@Test func sanitizedContentTypeStripsLineBreaksAndDefaults() {
    #expect(HTTPConnectionHandler.sanitizedContentType(" audio/mp4 ") == "audio/mp4")
    #expect(HTTPConnectionHandler.sanitizedContentType("") == "audio/mp4")
    #expect(HTTPConnectionHandler.sanitizedContentType("\r\n") == "audio/mp4")
    #expect(HTTPConnectionHandler.sanitizedContentType("audio/webm\r\nX-Evil: 1") == "audio/webmX-Evil: 1")
}

// MARK: - LRU-кэш LocalStream (аудит B-7)

@Test func localStreamCacheEvictsLeastRecentlyUsed() {
    let stream = LocalStream(upstream: URL(string: "https://example.invalid/audio.m4a")!, port: 1, maxCacheBytes: 250)
    let chunk = Data(repeating: 0xAA, count: 100)

    stream.storeCache(chunkLower: 0, data: chunk)
    stream.storeCache(chunkLower: LocalStream.chunkSize, data: chunk)
    #expect(stream.cachedChunkCount == 2)
    #expect(stream.cachedChunkBytes == 200)

    // Чтение чанка 0 обновляет время использования: LRU теперь чанк 1.
    #expect(stream.cachedData(forChunk: 0)?.count == 100)

    // Третий чанк превышает лимит 250 → вытесняется чанк 1, а не 0.
    stream.storeCache(chunkLower: 2 * LocalStream.chunkSize, data: chunk)
    #expect(stream.cachedData(forChunk: LocalStream.chunkSize) == nil)
    #expect(stream.cachedData(forChunk: 0) != nil)
    #expect(stream.cachedData(forChunk: 2 * LocalStream.chunkSize) != nil)
    #expect(stream.cachedChunkCount == 2)
    #expect(stream.cachedChunkBytes == 200)
}

@Test func localStreamCacheEvictsOldestStoredChunkWithoutReads() {
    let stream = LocalStream(upstream: URL(string: "https://example.invalid/audio.m4a")!, port: 1, maxCacheBytes: 250)
    let chunk = Data(repeating: 0xBB, count: 100)

    stream.storeCache(chunkLower: 0, data: chunk)
    stream.storeCache(chunkLower: LocalStream.chunkSize, data: chunk)
    stream.storeCache(chunkLower: 2 * LocalStream.chunkSize, data: chunk)

    #expect(stream.cachedData(forChunk: 0) == nil)
    #expect(stream.cachedData(forChunk: LocalStream.chunkSize) != nil)
    #expect(stream.cachedData(forChunk: 2 * LocalStream.chunkSize) != nil)
    #expect(stream.cachedChunkCount == 2)
}

@Test func localStreamCacheReplaceDoesNotDoubleCount() {
    let stream = LocalStream(upstream: URL(string: "https://example.invalid/audio.m4a")!, port: 1, maxCacheBytes: 250)
    let chunk = Data(repeating: 0xCC, count: 100)

    stream.storeCache(chunkLower: 0, data: chunk)
    stream.storeCache(chunkLower: 0, data: chunk)
    stream.storeCache(chunkLower: LocalStream.chunkSize, data: chunk)

    // 200 байт ≤ 250: замена не должна удваивать счётчик и провоцировать вытеснение.
    #expect(stream.cachedChunkCount == 2)
    #expect(stream.cachedChunkBytes == 200)
    #expect(stream.cachedData(forChunk: 0) != nil)
    #expect(stream.cachedData(forChunk: LocalStream.chunkSize) != nil)
}

@Test func localStreamCacheCloseDropsEverything() {
    let stream = LocalStream(upstream: URL(string: "https://example.invalid/audio.m4a")!, port: 1, maxCacheBytes: 250)
    stream.storeCache(chunkLower: 0, data: Data(repeating: 0xDD, count: 100))
    #expect(stream.cachedChunkCount == 1)
    stream.close()
    #expect(stream.cachedChunkCount == 0)
    #expect(stream.cachedData(forChunk: 0) == nil)
    stream.storeCache(chunkLower: 0, data: Data(count: 10))
    #expect(stream.cachedChunkCount == 0)
}

// MARK: - Loopback-фильтр соединений (аудит B-3)

@Test func loopbackHostDetection() {
    #expect(StreamHub.isLoopbackHost(.ipv4(IPv4Address.loopback)))
    #expect(StreamHub.isLoopbackHost(.ipv6(IPv6Address.loopback)))
    #expect(!StreamHub.isLoopbackHost(.ipv4(IPv4Address("203.0.113.10")!)))
    #expect(!StreamHub.isLoopbackHost(.ipv6(IPv6Address("2606:4700:4700::1111")!)))
    #expect(!StreamHub.isLoopbackHost(.name("localhost", nil)))
}
