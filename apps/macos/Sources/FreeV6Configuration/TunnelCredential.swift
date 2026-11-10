import CryptoKit
import Darwin
import Foundation

public enum ConfigurationValidationError: Error, LocalizedError, Sendable {
    case invalid, incompatible
    public var errorDescription: String? {
        switch self {
        case .invalid: return "连接配置格式或内容无效，请重新准备配置。"
        case .incompatible: return "连接配置与当前设置、凭据或资源版本不一致，请重新检查。"
        }
    }
}

public struct TunnelCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let privateKey: String
    public let peerPublicKey: String
    public let ipv4: String
    public let ipv6: String
    public var description: String { "TunnelCredential(redacted)" }
    public var debugDescription: String { description }

    public init(privateKey: String, peerPublicKey: String, ipv4: String, ipv6: String) {
        self.privateKey = privateKey; self.peerPublicKey = peerPublicKey; self.ipv4 = ipv4; self.ipv6 = ipv6
    }

    public func validated() throws -> Self {
        guard privateKey.utf8.count <= 4096, peerPublicKey.utf8.count <= 4096,
              let privateDER = Data(base64Encoded: privateKey), let peerDER = Data(base64Encoded: peerPublicKey),
              (try? P256.Signing.PrivateKey(derRepresentation: privateDER)) != nil,
              (try? P256.Signing.PublicKey(derRepresentation: peerDER)) != nil,
              validIPAddress(ipv4, family: AF_INET), validIPAddress(ipv6, family: AF_INET6) else { throw ConfigurationValidationError.invalid }
        return self
    }
}

func validIPAddress(_ value: String, family: Int32) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 45, !value.utf8.contains(0) else { return false }
    var bytes = [UInt8](repeating: 0, count: 16)
    guard value.withCString({ address in bytes.withUnsafeMutableBytes { inet_pton(family, address, $0.baseAddress) == 1 } }) else { return false }
    if family == AF_INET6 && bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 { return false }
    return true
}
