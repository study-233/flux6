import Foundation
import CryptoKit

public struct ChainProfileKey: Sendable {
    private let storage: any VersionedSecretStorage
    public init(storage: any VersionedSecretStorage = KeychainSecretStorage.chainKey()) { self.storage = storage }

    public func load(allowCreation: Bool) async throws -> Data {
        if let existing = try await storage.read() {
            guard existing.data.count == 32 else { throw CredentialError.invalidCredential }
            return existing.data
        }
        guard allowCreation else { throw MissingKey() }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        do { return try await storage.write(key, expectedRevision: nil).data }
        catch CredentialError.conflict { return try await load(allowCreation: false) }
    }

    private struct MissingKey: LocalizedError {
        var errorDescription: String? { "无法找到此链式配置的钥匙串密钥。请恢复密钥，或清除配置后重新导入。" }
    }
}
