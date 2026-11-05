import Foundation
import Security

public struct SecretSnapshot: Sendable {
    public let revision: UUID
    public let data: Data
    public init(revision: UUID, data: Data) { self.revision = revision; self.data = data }
}

public protocol VersionedSecretStorage: Sendable {
    func read() async throws -> SecretSnapshot?
    func write(_ data: Data, expectedRevision: UUID?) async throws -> SecretSnapshot
    func delete(expectedRevision: UUID) async throws
}

// The file-based user Keychain uses the creating app's default code ACL. No
// all-apps access, shared access group or Apple signing entitlement is granted.
// Calls may invoke system authentication and are only started by user actions.
public final class KeychainSecretStorage: VersionedSecretStorage, @unchecked Sendable {
    private let service: String
    private let account: String
    private let label: String
    private let keychain: SecKeychain?
    private let queue = DispatchQueue(label: "dev.freev6.credentials")

    public init() {
        service = "dev.freev6.desktop.warp"
        account = "credentials-v1"
        label = "FreeV6 WARP 凭据"
        keychain = nil
    }

    public static func cloudKey() -> KeychainSecretStorage {
        KeychainSecretStorage(service: "dev.freev6.desktop.cloud", account: "snapshot-key-v1", keychain: nil, label: "FreeV6 备用配置密钥")
    }

    public static func chainKey() -> KeychainSecretStorage {
        KeychainSecretStorage(service: "dev.freev6.desktop.chain", account: "snapshot-key-v1", keychain: nil, label: "FreeV6 链式代理密钥")
    }

    init(service: String, account: String, keychain: SecKeychain?, label: String = "FreeV6 WARP 凭据") {
        self.service = service; self.account = account; self.keychain = keychain; self.label = label
    }

    private func query() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    public func read() async throws -> SecretSnapshot? {
        try await perform {
            var query = self.query()
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw CredentialError.security(status) }
            guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
                  let version = item[kSecAttrGeneric as String] as? Data,
                  let text = String(data: version, encoding: .utf8), let revision = UUID(uuidString: text),
                  data.count <= 32_768 else { throw CredentialError.invalidCredential }
            return SecretSnapshot(revision: revision, data: data)
        }
    }

    public func write(_ data: Data, expectedRevision: UUID?) async throws -> SecretSnapshot {
        guard !data.isEmpty, data.count <= 32_768 else { throw CredentialError.invalidCredential }
        return try await perform {
            let revision = UUID()
            var query = self.query()
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrGeneric as String: Data(revision.uuidString.utf8),
                kSecAttrLabel as String: self.label,
            ]
            let status: OSStatus
            if let expectedRevision {
                query[kSecAttrGeneric as String] = Data(expectedRevision.uuidString.utf8)
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            } else {
                query.removeValue(forKey: kSecMatchSearchList as String)
                if let keychain = self.keychain { query[kSecUseKeychain as String] = keychain }
                query.merge(update) { _, new in new }
                status = SecItemAdd(query as CFDictionary, nil)
            }
            if status == errSecDuplicateItem || status == errSecItemNotFound { throw CredentialError.conflict }
            guard status == errSecSuccess else { throw CredentialError.security(status) }
            return SecretSnapshot(revision: revision, data: data)
        }
    }

    public func delete(expectedRevision: UUID) async throws {
        try await perform {
            var query = self.query()
            query[kSecAttrGeneric as String] = Data(expectedRevision.uuidString.utf8)
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { throw CredentialError.conflict }
            guard status == errSecSuccess else { throw CredentialError.security(status) }
        }
    }

    private func perform<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: action)) }
        }
    }
}
