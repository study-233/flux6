import Foundation

public struct RegisteredClient: Codable, Equatable {
    public let uid: UInt32
    public let identity: CodeIdentity

    public init(uid: UInt32, identity: CodeIdentity) {
        self.uid = uid
        self.identity = identity
    }
}

/// Written only by the administrator-authorized installer. Neither the app nor
/// any XPC method can enroll a new client or choose an executable to run.
public struct ServiceRegistration: Codable, Equatable {
    public static let schemaVersion = 1
    public static let maximumBytes = 32 * 1024
    public static let maximumClients = 16

    public let schema: Int
    public let service: CodeIdentity
    public let clients: [RegisteredClient]

    public init(service: CodeIdentity, clients: [RegisteredClient]) throws {
        guard !clients.isEmpty, clients.count <= Self.maximumClients else {
            throw RegistrationError.invalidClients
        }
        self.schema = Self.schemaVersion
        self.service = service
        self.clients = clients
    }

    public static func decode(_ data: Data) throws -> ServiceRegistration {
        guard data.count <= maximumBytes else { throw RegistrationError.oversized }
        let value = try JSONDecoder().decode(ServiceRegistration.self, from: data)
        guard value.schema == schemaVersion else { throw RegistrationError.incompatibleSchema }
        guard !value.clients.isEmpty, value.clients.count <= maximumClients else { throw RegistrationError.invalidClients }
        return value
    }

    public func requirement(for uid: UInt32) -> String? {
        let hashes = Set(clients.filter { $0.uid == uid }.map { $0.identity.cdHash }).sorted()
        guard !hashes.isEmpty else { return nil }
        return hashes.map { "(cdhash H\"\($0)\")" }.joined(separator: " or ")
    }
}

public enum RegistrationError: Error, LocalizedError {
    case oversized, incompatibleSchema, invalidClients, insecureFile, serviceIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case .oversized: return "服务登记文件过大"
        case .incompatibleSchema: return "服务登记格式不兼容"
        case .invalidClients: return "服务登记的客户端列表无效"
        case .insecureFile: return "服务登记文件的所有者或权限不符合要求"
        case .serviceIdentityMismatch: return "服务代码身份与安装登记不一致"
        }
    }
}

public enum ServicePaths {
    public static let executable = "/Library/PrivilegedHelperTools/dev.freev6.network-service"
    public static let registration = "/Library/Application Support/dev.freev6.desktop/service-registration.json"
    public static let launchDaemon = "/Library/LaunchDaemons/dev.freev6.network-service.plist"
}
