import Foundation
import Security

/// Where the signed-in tokens live. The Keychain on devices; memory in tests.
public protocol TokenStore: AnyObject, Sendable {
    var tokens: TokenSet? { get }
    func save(_ tokens: TokenSet?)
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: TokenSet?

    public init(_ tokens: TokenSet?) {
        stored = tokens
    }

    public var tokens: TokenSet? {
        lock.withLock { stored }
    }

    public func save(_ tokens: TokenSet?) {
        lock.withLock { stored = tokens }
    }
}

/// One Keychain generic-password item per server, holding the JSON-encoded token pair.
/// Saved only when the device is unlocked, and never synced to iCloud.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {

    private let service = "com.beesroadhouse.nectar.tokens"
    private let account: String

    public init(server: URL) {
        account = server.absoluteString
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public var tokens: TokenSet? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
