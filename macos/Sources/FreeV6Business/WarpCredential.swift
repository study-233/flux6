import Foundation
import FreeV6Configuration

public struct WarpCredential: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Device: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let deviceId: String
        public let token: String
        public let privateKey: String
        public let peerPublicKey: String
        public let ipv4: String
        public let ipv6: String
        public let registeredAt: String
        public var description: String { "WarpDevice(redacted)" }
        public var debugDescription: String { description }
    }
    public let schemaVersion: Int
    public let device: Device
    public var description: String { "WarpCredential(redacted)" }
    public var debugDescription: String { description }

    public func tunnelCredential() throws -> TunnelCredential {
        _ = try validated()
        return try TunnelCredential(privateKey: device.privateKey, peerPublicKey: device.peerPublicKey,
                                    ipv4: device.ipv4, ipv6: device.ipv6).validated()
    }

    public func validated() throws -> Self {
        let identifier = device.deviceId.utf8
        guard schemaVersion == 1, !identifier.isEmpty, identifier.count <= 256,
              identifier.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              !device.token.isEmpty, device.token.utf8.count <= 8192,
              device.token.utf8.allSatisfy({ (33...126).contains($0) }),
              (try? TunnelCredential(privateKey: device.privateKey, peerPublicKey: device.peerPublicKey,
                                     ipv4: device.ipv4, ipv6: device.ipv6).validated()) != nil,
              device.registeredAt.utf8.count <= 64 else { throw CredentialError.invalidCredential }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: device.registeredAt) == nil {
            formatter.formatOptions = [.withInternetDateTime]
            guard formatter.date(from: device.registeredAt) != nil else { throw CredentialError.invalidCredential }
        }
        return self
    }

}

public enum CredentialError: Error, LocalizedError, Equatable, Sendable {
    case invalidCredential, conflict, security(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "WARP 凭据格式无效。原有存储已保留。"
        case .conflict: return "已保存的凭据发生变化。请重新检查后再操作。"
        case .security(-128): return "已取消钥匙串授权。凭据未保存或读取。"
        case .security(-25308): return "钥匙串需要解锁或授权。请打开 FreeV6 手动检查凭据。"
        case .security(let status): return "钥匙串操作未完成（\(status)）。请检查系统授权后重试。"
        }
    }
}

public struct StoredWarpCredential: Sendable {
    public let revision: UUID
    public let credential: WarpCredential
}

public actor WarpCredentialVault {
    private let storage: any VersionedSecretStorage
    public init(storage: any VersionedSecretStorage = KeychainSecretStorage()) { self.storage = storage }

    public func load(interactionAllowed: Bool = true) async throws -> StoredWarpCredential? {
        guard let item = try await storage.read(interactionAllowed: interactionAllowed) else { return nil }
        guard item.data.count <= 32_768 else { throw CredentialError.invalidCredential }
        let credential: WarpCredential
        do { credential = try JSONDecoder().decode(WarpCredential.self, from: item.data).validated() }
        catch { throw CredentialError.invalidCredential }
        return StoredWarpCredential(revision: item.revision, credential: credential)
    }

    public func save(_ credential: WarpCredential, expectedRevision: UUID?) async throws -> StoredWarpCredential {
        let value = try credential.validated()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 32_768 else { throw CredentialError.invalidCredential }
        let item = try await storage.write(data, expectedRevision: expectedRevision)
        return StoredWarpCredential(revision: item.revision, credential: value)
    }

    public func delete(expectedRevision: UUID) async throws { try await storage.delete(expectedRevision: expectedRevision) }
}
