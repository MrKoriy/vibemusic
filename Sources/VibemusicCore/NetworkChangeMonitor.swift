import Foundation
import Network
import os

/// Следит за сменой сетевого маршрута (другой Wi‑Fi, VPN вкл/выкл, Ethernet).
/// Ссылки googlevideo привязаны к IP запросившего, поэтому после смены сети
/// кэш ссылок сбрасывается: иначе прямой маршрут (отпечаток nil) до ~6 ч
/// получал бы 403 на старых ссылках.
public final class NetworkChangeMonitor: @unchecked Sendable {
    public static let shared = NetworkChangeMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vibemusic.network.monitor", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var lastSignature: String?
    private let logger = Logger(subsystem: "com.vibemusic.app", category: "network")

    /// Вызывается при смене маршрута (на фоновой очереди).
    public var onChange: @Sendable () -> Void = { StreamURLCache.shared.removeAll() }

    private init() {}

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    private func handle(_ path: NWPath) {
        let signature = Self.signature(of: path)
        lock.lock()
        let previous = lastSignature
        lastSignature = signature
        let callback = onChange
        lock.unlock()
        // Первый колбэк — исходное состояние, не смена.
        guard let previous, previous != signature else { return }
        logger.info("network route changed, dropping stream URL cache")
        callback()
    }

    /// Отпечаток маршрута: статус + имена и типы активных интерфейсов.
    /// Чистая функция над NWPath, чтобы мелкие апдейты (например, флаг
    /// isExpensive) не сбрасывали кэш зря.
    static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\($0.type)" }
            .joined(separator: ",")
        return "\(path.status)|\(interfaces)"
    }
}
