import Foundation
import Security

/// Explicit shared group, separate from the app's existing private sync keys.
enum ActivityDisplayKeychain {
    struct Configuration: Codable {
        let key: Data
        let languageCode: String
    }
    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FelixActivityKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.jonbright.FelixFeeds.activity-display",
                kSecAttrAccount as String: "v1", kSecAttrAccessGroup as String: group]
    }
    static func load() -> Configuration? {
        guard var query else { return nil }
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    static func save(_ configuration: Configuration) throws {
        guard let query else { throw KeychainError.unavailable }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(configuration),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw KeychainError.unavailable
            }
        } else if result != errSecSuccess { throw KeychainError.unavailable }
    }
    enum KeychainError: Error { case unavailable }
}
