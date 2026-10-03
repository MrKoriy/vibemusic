import Foundation
import Security

/// Хранилище секретов (адрес прокси с логином/паролем).
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    /// Пустая строка или nil — удалить. Возвращает false при ошибке записи.
    @discardableResult
    func write(_ value: String?, for key: String) -> Bool
}

/// Связка ключей macOS (login keychain, generic password).
/// Значения кэшируются в памяти: ProxyConfig.load() вызывается на каждый трек.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let shared = KeychainSecretStore()

    private let service: String
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init(service: String = "com.vibemusic.app") {
        self.service = service
    }

    public func read(_ key: String) -> String? {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value: String?
        if status == errSecSuccess, let data = item as? Data {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        // Кэшируем только определённый ответ: «нашли» или «точно нет».
        if status == errSecSuccess || status == errSecItemNotFound {
            lock.lock()
            cache[key] = .some(value)
            lock.unlock()
        }
        return value
    }

    @discardableResult
    public func write(_ value: String?, for key: String) -> Bool {
        let normalized = (value?.isEmpty ?? true) ? nil : value
        lock.lock()
        if let cached = cache[key], cached == normalized {
            lock.unlock()
            return true
        }
        lock.unlock()

        let query = baseQuery(key)
        let ok: Bool
        if let normalized {
            let data = Data(normalized.utf8)
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = "Vibemusic: \(key)"
                status = SecItemAdd(add as CFDictionary, nil)
            }
            ok = status == errSecSuccess
        } else {
            let status = SecItemDelete(query as CFDictionary)
            ok = status == errSecSuccess || status == errSecItemNotFound
        }
        if ok {
            lock.lock()
            cache[key] = .some(normalized)
            lock.unlock()
        }
        return ok
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Секреты прямо в UserDefaults. Используется для нестандартных
/// UserDefaults (тесты и т. п.), чтобы не трогать настоящую связку ключей.
public struct DefaultsSecretStore: SecretStore, @unchecked Sendable {
    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func read(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    @discardableResult
    public func write(_ value: String?, for key: String) -> Bool {
        defaults.set(value, forKey: key)
        return true
    }
}

/// Хранилище в памяти — для тестов.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public var failWrites = false

    public init() {}

    public func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    public func write(_ value: String?, for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { return false }
        if let value, !value.isEmpty {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        return true
    }
}
