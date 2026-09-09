import Foundation
import Testing
@testable import VibemusicCore

/// Фейк-резолвер: считает вызовы, умеет задержки и ошибки.
private final class FakeResolve: @unchecked Sendable {
    var callCount = 0
    var delay: TimeInterval
    var shouldFail: Bool

    init(delay: TimeInterval = 0, shouldFail: Bool = true) {
        self.delay = delay
        self.shouldFail = shouldFail
    }

    func makeHandler() -> (String, String?) async throws -> (URL, Bool) {
        { [weak self] _, _ in
            guard let self else { throw URLError(.cancelled) }
            self.callCount += 1
            if self.delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
            }
            if self.shouldFail {
                throw URLError(.badURL)
            }
            return (URL(string: "https://example.com/audio.m4a")!, false)
        }
    }
}

private func makeCategory(count: Int) -> MusicCategory {
    let tracks = (0..<count).map { Track(id: "vid0000000\($0)xx", title: "Track \($0)") }
    return MusicCategory(id: "test", title: "Тест", mode: .focus, defaultMinutes: 25, tracks: tracks)
}

/// Тайминговые тесты: сериализуем, чтобы параллельные сюиты не сбивали раскладку MainActor.
@Suite(.serialized)
@MainActor
struct PlayerRaceTests {

    @Test func resetDuringResolveDoesNotResurrect() async throws {
        let player = PlayerCore()
        let fake = FakeResolve(delay: 0.4, shouldFail: true)
        player.resolve = fake.makeHandler()

        player.play(category: makeCategory(count: 3), shuffle: false)
        #expect(player.isLoading == true)

        player.reset()
        #expect(player.isLoading == false)
        #expect(player.needsRetry == false)
        #expect(player.statusText == nil)

        // Резолв завершается ПОСЛЕ сброса — состояние не должно измениться.
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(player.isLoading == false)
        #expect(player.statusText == nil)
        #expect(player.current == nil)
        #expect(fake.callCount == 1)
    }

    @Test func stopAndNextKeepVolumeIntact() async throws {
        let player = PlayerCore()
        player.setVolume(0.8)
        let fake = FakeResolve(delay: 0, shouldFail: true)
        player.resolve = fake.makeHandler()

        player.play(category: makeCategory(count: 2), shuffle: false)
        try await Task.sleep(nanoseconds: 150_000_000)

        // stop без item — мгновенная остановка, громкость не искажается.
        player.stop(fade: true)
        #expect(player.playerVolume == 0.8)
        #expect(player.isFadeActive == false)

        // Новая загрузка не наследует никаких артефактов.
        player.next()
        #expect(player.playerVolume == 0.8)
        #expect(player.isFadeActive == false)
        #expect(player.isLoading == true)
    }

    @Test func singleTrackFailureRequiresRetry() async throws {
        let player = PlayerCore()
        let fake = FakeResolve(delay: 0, shouldFail: true)
        player.resolve = fake.makeHandler()

        player.play(category: makeCategory(count: 1), shuffle: false)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(player.needsRetry == true)
        #expect(player.statusText?.contains("↻") == true)

        player.retry()
        #expect(player.needsRetry == false)
        #expect(player.isLoading == true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(player.needsRetry == true)
        #expect(fake.callCount == 2)
    }

    @Test func slowResolveFailureSkipsAutoNext() async throws {
        let player = PlayerCore()
        let fake = FakeResolve(delay: YTResolver.slowResolveThreshold + 1.0, shouldFail: true)
        player.resolve = fake.makeHandler()

        player.play(category: makeCategory(count: 3), shuffle: false)
        let firstTrackID = player.current?.id
        // Ждём с запасом: задержка фейка + время на MainActor-переключения.
        try await Task.sleep(nanoseconds: UInt64((YTResolver.slowResolveThreshold + 3.0) * 1_000_000_000))

        #expect(player.statusText?.contains("YouTube недоступен") == true)
        #expect(player.needsRetry == true)
        // autoNext НЕ сработал: резолв вызывался ровно один раз.
        #expect(fake.callCount == 1)
        #expect(player.current?.id == firstTrackID)
    }

    @Test func fastFailureWithQueueAdvances() async throws {
        let player = PlayerCore()
        let fake = FakeResolve(delay: 0, shouldFail: true)
        player.resolve = fake.makeHandler()

        player.play(category: makeCategory(count: 2), shuffle: false)
        // autoNext задержка 1.5 с + загрузка.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        #expect(fake.callCount >= 2)
        #expect(player.needsRetry == false)
    }

    @Test func retryCancelsPendingAutoNext() async throws {
        let player = PlayerCore()
        let fake = FakeResolve(delay: 0.3, shouldFail: true)
        player.resolve = fake.makeHandler()

        player.play(category: makeCategory(count: 2), shuffle: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Первая загрузка отменяется retry.
        player.retry()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(player.isLoading == true)
        #expect(fake.callCount == 2)

        // Вторая загрузка фейлится (~0.3с) → планирует autoNext через 1.5с (выстрелил бы в ~1.9с от старта).
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(fake.callCount == 2)

        // Сразу отменяем ожидающий autoNext повторным retry; новый резолв делаем длинным,
        // чтобы он сам не успел зафейлиться и запланировать новый autoNext.
        fake.delay = 10.0
        player.retry()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Ждём дольше момента, когда стрельнул бы ОТМЕНЁННЫЙ autoNext (~1.9с).
        try await Task.sleep(nanoseconds: 2_200_000_000)
        #expect(fake.callCount == 3)

        // Чистим за собой: отменяем длинный резолв.
        player.reset()
    }
}
