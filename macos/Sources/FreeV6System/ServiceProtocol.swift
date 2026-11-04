import Foundation

public enum ServiceProtocolVersion {
    public static let current = 1
    public static let machService = "dev.freev6.network-service"
}

/// XPC only transports bounded data. The service decodes and validates the DTO
/// before dispatching an operation, rather than accepting arbitrary objects.
@objc public protocol NetworkServiceProtocol {
    func handshake(_ request: Data, reply: @escaping (Data?, String?) -> Void)
}

public struct HandshakeRequest: Codable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID

    public init(protocolVersion: Int = ServiceProtocolVersion.current, requestID: UUID = UUID()) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
    }
}

public struct HandshakeReply: Codable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let serviceVersion: String
    public let privileged: Bool

    public init(requestID: UUID, serviceVersion: String, privileged: Bool) {
        self.protocolVersion = ServiceProtocolVersion.current
        self.requestID = requestID
        self.serviceVersion = serviceVersion
        self.privileged = privileged
    }
}

public enum ServiceMessageError: Error, LocalizedError {
    case oversized
    case incompatibleVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .oversized: return "服务消息超过允许的大小"
        case .incompatibleVersion(let version): return "不兼容的服务协议版本：\(version)"
        }
    }
}

public enum ServiceMessages {
    public static let maximumHandshakeBytes = 4096

    public static func decodeHandshake(_ data: Data) throws -> HandshakeRequest {
        guard data.count <= maximumHandshakeBytes else { throw ServiceMessageError.oversized }
        let request = try JSONDecoder().decode(HandshakeRequest.self, from: data)
        guard request.protocolVersion == ServiceProtocolVersion.current else {
            throw ServiceMessageError.incompatibleVersion(request.protocolVersion)
        }
        return request
    }
}
