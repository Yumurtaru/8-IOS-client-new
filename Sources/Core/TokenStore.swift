import Foundation
import Security

/// Токены входа (access + refresh) — в Keychain, а не в UserDefaults.
///
/// UserDefaults — это обычный plist в папке приложения: он попадает в
/// незашифрованные резервные копии iTunes/Finder, и по refresh-токену оттуда
/// можно 30 дней получать новые access-токены. Keychain с доступом
/// «после первой разблокировки, только на этом устройстве» такого не допускает.
///
/// Старые версии приложения писали токены в UserDefaults — при первом чтении
/// они переносятся в Keychain и удаляются оттуда (человеку входить заново не нужно).
enum TokenStore {
    private static let accessKey = "ru.marketplace.client.access_token"
    private static let refreshKey = "ru.marketplace.client.refresh_token"
    private static let legacyAccess = "token"
    private static let legacyRefresh = "refresh_token"

    /// Access-токен (JWT) или nil.
    static var access: String? {
        get { value(accessKey, legacy: legacyAccess) }
        set { store(newValue, key: accessKey, legacy: legacyAccess) }
    }

    /// Refresh-токен (30 дней) или nil.
    static var refresh: String? {
        get { value(refreshKey, legacy: legacyRefresh) }
        set { store(newValue, key: refreshKey, legacy: legacyRefresh) }
    }

    static func clear() {
        store(nil, key: accessKey, legacy: legacyAccess)
        store(nil, key: refreshKey, legacy: legacyRefresh)
    }

    // MARK: - Keychain

    private static func value(_ key: String, legacy: String) -> String? {
        if let v = read(key) { return v }
        // Перенос из старой версии: был в UserDefaults — кладём в Keychain.
        if let old = UserDefaults.standard.string(forKey: legacy), !old.isEmpty {
            if write(old, key: key) { UserDefaults.standard.removeObject(forKey: legacy) }
            return old
        }
        return nil
    }

    private static func store(_ value: String?, key: String, legacy: String) {
        UserDefaults.standard.removeObject(forKey: legacy)
        if let v = value, !v.isEmpty {
            if !write(v, key: key) {
                // Keychain недоступен (крайне редко) — не теряем вход в этой сессии.
                UserDefaults.standard.set(v, forKey: legacy)
            }
        } else {
            delete(key)
        }
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ru.marketplace.client",
         kSecAttrAccount as String: key]
    }

    private static func read(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    private static func write(_ value: String, key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let q = baseQuery(key)
        SecItemDelete(q as CFDictionary)
        var attrs = q
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
