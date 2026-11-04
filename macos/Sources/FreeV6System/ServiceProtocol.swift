import Foundation

public enum ServiceProtocolVersion {
    public static let current = 3
    public static let machService = "dev.freev6.network-service"
}

/// XPC carries bounded JSON metadata and, for approved resource installation,
/// a file descriptor. The service validates both before dispatching an operation.
@objc public protocol NetworkServiceProtocol {
    func handshake(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    func resourceStatus(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    func installApprovedResource(_ request: Data, source: FileHandle, reply: @escaping (Data?, String?) -> Void)
    func checkConfiguration(_ request: Data, reply: @escaping (Data?, String?) -> Void)
}

public struct ResourceRequest: Codable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let resourceID: String?
    public init(resourceID: String? = nil) {
        protocolVersion = ServiceProtocolVersion.current
        requestID = UUID()
        self.resourceID = resourceID
    }
}

public struct ResourceAvailability: Codable, Equatable {
    public let id: String
    public let available: Bool
}

public struct ResourceReply: Codable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let resources: [ResourceAvailability]
    public init(requestID: UUID, resources: [ResourceAvailability]) {
        protocolVersion = ServiceProtocolVersion.current
        self.requestID = requestID
        self.resources = resources
    }
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
    case invalid
    case incompatibleVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .oversized: return "服务消息超过允许的大小"
        case .invalid: return "服务请求字段无效"
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

    public static func decodeResource(_ data: Data, installing: Bool) throws -> ResourceRequest {
        guard data.count <= maximumHandshakeBytes else { throw ServiceMessageError.oversized }
        let expected: Set<String> = installing ? ["protocolVersion", "requestID", "resourceID"] : ["protocolVersion", "requestID"]
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == expected else { throw ServiceMessageError.invalid }
        let request = try JSONDecoder().decode(ResourceRequest.self, from: data)
        guard request.protocolVersion == ServiceProtocolVersion.current else {
            throw ServiceMessageError.incompatibleVersion(request.protocolVersion)
        }
        if installing {
            guard let id = request.resourceID else { throw ServiceMessageError.invalid }
            _ = try ApprovedResourceCatalog.asset(id)
        }
        return request
    }
}
