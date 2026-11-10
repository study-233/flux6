import Foundation
import Security

public struct SecretSnapshot: Sendable {
    public let revision: UUID
    public let data: Data
    public init(revision: UUID, data: Data) { self.revision = revision; self.data = data }
}

public protocol VersionedSecretStorage: Sendable {
    func read() async throws -> SecretSnapshot?
    func read(interactionAllowed: Bool) async throws -> SecretSnapshot?
    func write(_ data: Data, expectedRevision: UUID?) async throws -> SecretSnapshot
    func write(_ data: Data, expectedRevision: UUID?, interactionAllowed: Bool) async throws -> SecretSnapshot
    func delete(expectedRevision: UUID) async throws
}

public extension VersionedSecretStorage {
    func write(_ data: Data, expectedRevision: UUID?, interactionAllowed: Bool) async throws -> SecretSnapshot {
        guard interactionAllowed else { throw CredentialError.security(errSecInteractionNotAllowed) }
        return try await write(data, expectedRevision: expectedRevision)
    }
    func read(interactionAllowed: Bool) async throws -> SecretSnapshot? {
        guard interactionAllowed else { throw CredentialError.security(errSecInteractionNotAllowed) }
        return try await read()
    }
}

// The file-based user Keychain uses the creating app's default code ACL. No
// all-apps access, shared access group or Apple signing entitlement is granted.
// All file-based Keychain calls share one queue. Background reads suppress
// Keychain UI for their synchronous lookup and restore the process setting.
public final class KeychainSecretStorage: VersionedSecretStorage, @unchecked Sendable {
    private let service: String
    private let account: String
    private let label: String
    private let keychain: SecKeychain?
    private static let queue = DispatchQueue(label: "dev.freev6.credentials")
    // Process memory only. Every reuse checks the item's revision, modification
    // date and Keychain lock state without requesting secret data or showing UI.
    private var cached: (item: SecretSnapshot, modified: Date, until: TimeInterval)?
    #if DEBUG
    private var secretReads = 0
    func secretReadsForTesting() async throws -> Int { try await perform { self.secretReads } }
    #endif

    public init() {
        service = "dev.freev6.desktop.warp"
        account = "credentials-v1"
        label = "Flux6 WARP 凭据"
        keychain = nil
    }

    public static func cloudKey() -> KeychainSecretStorage {
        KeychainSecretStorage(service: "dev.freev6.desktop.cloud", account: "snapshot-key-v1", keychain: nil, label: "Flux6 备用配置密钥")
    }

    public static func chainKey() -> KeychainSecretStorage {
        KeychainSecretStorage(service: "dev.freev6.desktop.chain", account: "snapshot-key-v1", keychain: nil, label: "Flux6 链式代理密钥")
    }

    public static func integrationProfileKey(chain: Bool) -> KeychainSecretStorage {
        let kind = chain ? "chain" : "cloud"
        return KeychainSecretStorage(service: "dev.freev6.integration." + kind, account: "snapshot-key-v1", keychain: nil,
                                     label: chain ? "Flux6 验收版链式配置" : "Flux6 验收版备用配置")
    }

    init(service: String, account: String, keychain: SecKeychain?, label: String = "Flux6 WARP 凭据") {
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
        try await read(interactionAllowed: true)
    }

    public func read(interactionAllowed: Bool) async throws -> SecretSnapshot? {
        try await perform {
            if let cached = self.cached {
                if ProcessInfo.processInfo.systemUptime < cached.until,
                   let stamp = try? self.metadata(), stamp.revision == cached.item.revision,
                   stamp.modified == cached.modified {
                    return cached.item
                }
                self.cached = nil
            }
            var restore = false
            if !interactionAllowed {
                var previous = DarwinBoolean(false)
                let status = SecKeychainGetUserInteractionAllowed(&previous)
                guard status == errSecSuccess else { throw CredentialError.security(status) }
                if previous.boolValue {
                    let disabled = SecKeychainSetUserInteractionAllowed(false)
                    guard disabled == errSecSuccess else { throw CredentialError.security(disabled) }
                    restore = true
                }
            }
            defer { if restore { SecKeychainSetUserInteractionAllowed(true) } }
            var query = self.query()
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            #if DEBUG
            self.secretReads += 1
            #endif
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            if !interactionAllowed && status == errSecAuthFailed { throw CredentialError.security(errSecInteractionNotAllowed) }
            guard status == errSecSuccess else { throw CredentialError.security(status) }
            guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
                  let version = item[kSecAttrGeneric as String] as? Data,
                  let text = String(data: version, encoding: .utf8), let revision = UUID(uuidString: text),
                  data.count <= 32_768 else { throw CredentialError.invalidCredential }
            let snapshot = SecretSnapshot(revision: revision, data: data)
            self.remember(snapshot)
            return snapshot
        }
    }

    public func write(_ data: Data, expectedRevision: UUID?) async throws -> SecretSnapshot {
        try await write(data, expectedRevision: expectedRevision, interactionAllowed: true)
    }

    public func write(_ data: Data, expectedRevision: UUID?, interactionAllowed: Bool) async throws -> SecretSnapshot {
        guard !data.isEmpty, data.count <= 32_768 else { throw CredentialError.invalidCredential }
        return try await perform {
            // Automatic connection must never summon a Keychain dialog.
            // Keep the setting scoped to this serialized synchronous operation.
            var previous = DarwinBoolean(false)
            let statusBefore = SecKeychainGetUserInteractionAllowed(&previous)
            guard statusBefore == errSecSuccess else { throw CredentialError.security(statusBefore) }
            if !interactionAllowed && previous.boolValue {
                let status = SecKeychainSetUserInteractionAllowed(false)
                guard status == errSecSuccess else { throw CredentialError.security(status) }
            }
            defer { if !interactionAllowed && previous.boolValue { SecKeychainSetUserInteractionAllowed(true) } }
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
            if !interactionAllowed && status == errSecAuthFailed { throw CredentialError.security(errSecInteractionNotAllowed) }
            guard status == errSecSuccess else { throw CredentialError.security(status) }
            let snapshot = SecretSnapshot(revision: revision, data: data)
            self.remember(snapshot)
            return snapshot
        }
    }

    public func delete(expectedRevision: UUID) async throws {
        try await perform {
            self.cached = nil
            var query = self.query()
            query[kSecAttrGeneric as String] = Data(expectedRevision.uuidString.utf8)
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { throw CredentialError.conflict }
            guard status == errSecSuccess else { throw CredentialError.security(status) }
        }
    }

    private func remember(_ item: SecretSnapshot) {
        cached = nil
        if let stamp = try? metadata(), stamp.revision == item.revision {
            cached = (item, stamp.modified, ProcessInfo.processInfo.systemUptime + 300)
        }
    }

    private func metadata() throws -> (revision: UUID, modified: Date) {
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else { throw CredentialError.invalidCredential }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw CredentialError.invalidCredential }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw CredentialError.security(status) }
        guard let fields = result as? [String: Any], let version = fields[kSecAttrGeneric as String] as? Data,
              let text = String(data: version, encoding: .utf8), let revision = UUID(uuidString: text),
              let modified = fields[kSecAttrModificationDate as String] as? Date,
              let ref = fields[kSecValueRef as String], CFGetTypeID(ref as CFTypeRef) == SecKeychainItemGetTypeID() else {
            throw CredentialError.invalidCredential
        }
        let item = ref as! SecKeychainItem
        var chain: SecKeychain?
        guard SecKeychainItemCopyKeychain(item, &chain) == errSecSuccess, let chain else { throw CredentialError.invalidCredential }
        var flags: SecKeychainStatus = 0
        guard SecKeychainGetStatus(chain, &flags) == errSecSuccess, flags & kSecUnlockStateStatus != 0 else {
            throw CredentialError.security(errSecInteractionNotAllowed)
        }
        return (revision, modified)
    }

    private func perform<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result(catching: action)) }
        }
    }
}
