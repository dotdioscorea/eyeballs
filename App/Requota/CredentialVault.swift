import Foundation
import Security

// One credential record per connection. Perplexity stores its own passwordless
// session token; other providers use OAuth tokens. No shared browser session.
struct AccountCredential: Codable, Equatable, Sendable {
    var provider: Provider
    var issuer: String
    var clientID: String
    var subject: String
    var accountID: String?
    var hostID: String
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var scopes: [String]
    var expiresAt: Date
    var email: String?
    var registrationIdentity: String { [issuer, clientID, subject, accountID ?? ""].joined(separator: "|") }
}

protocol CredentialStorage {
    func save(_ credential: AccountCredential, id: UUID) throws
    func load(id: UUID) throws -> AccountCredential?
    func delete(id: UUID) throws
}

struct CredentialVault: CredentialStorage {
    static let service = "com.dotdioscorea.eyeballs.credentials.v2"
    func save(_ credential: AccountCredential, id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let query = base(id)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; changes.forEach { insert[$0] = $1 }
            let inserted = SecItemAdd(insert as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw VaultError.status(inserted) }
        } else if status != errSecSuccess { throw VaultError.status(status) }
    }
    func load(id: UUID) throws -> AccountCredential? {
        var query = base(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.status(status) }
        return try JSONDecoder().decode(AccountCredential.self, from: data)
    }
    func delete(id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.status(status) }
    }
    private func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    enum VaultError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? { "The secure connection could not be stored. Please try again." }
    }
}
