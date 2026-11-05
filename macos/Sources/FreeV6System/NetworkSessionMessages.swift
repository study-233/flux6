import Foundation

public enum NetworkSessionPhase: String, Codable, Sendable { case stopped, running, recoveryRequired, occupied }

public struct NetworkSessionReply: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let phase: NetworkSessionPhase
    public let idleToken: UUID?
    public let sessionID: UUID?
    public let revision: UInt64?
    public let settingsRevision: UInt64?
    public let credentialRevision: UUID?

    init(_ id: UUID, phase: NetworkSessionPhase, idleToken: UUID? = nil, record: PreparedSessionRecord? = nil) {
        protocolVersion = ServiceProtocolVersion.current
        requestID = id
        self.phase = phase
        self.idleToken = idleToken
        sessionID = record?.sessionID
        revision = record?.run?.revision
        settingsRevision = record?.settingsRevision
        credentialRevision = record?.credentialRevision
    }

    static func decode(_ data: Data, id: UUID) throws -> Self {
        guard data.count <= ServiceMessages.maximumHandshakeBytes,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceClientError.invalidReply }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard reply.protocolVersion == ServiceProtocolVersion.current, reply.requestID == id else { throw ServiceClientError.invalidReply }
        var keys: Set<String> = ["protocolVersion", "requestID", "phase"]
        switch reply.phase {
        case .stopped:
            guard reply.idleToken != nil else { throw ServiceClientError.invalidReply }
            keys.insert("idleToken")
        case .occupied: break
        case .recoveryRequired where reply.sessionID == nil: break
        case .running, .recoveryRequired:
            guard reply.sessionID != nil, let revision = reply.revision, revision > 0,
                  reply.settingsRevision != nil, reply.credentialRevision != nil else { throw ServiceClientError.invalidReply }
            keys.formUnion(["sessionID", "revision", "settingsRevision", "credentialRevision"])
        }
        guard Set(fields.keys) == keys else { throw ServiceClientError.invalidReply }
        return reply
    }
}

struct NetworkSessionQuery: Codable {
    let protocolVersion: Int
    let requestID: UUID
    let sessionID: UUID?
    let revision: UInt64?

    init(sessionID: UUID? = nil, revision: UInt64? = nil) {
        protocolVersion = ServiceProtocolVersion.current
        requestID = UUID()
        self.sessionID = sessionID
        self.revision = revision
    }
    static func decode(_ data: Data, stopping: Bool) throws -> Self {
        guard data.count <= ServiceMessages.maximumHandshakeBytes,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceMessageError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.protocolVersion == ServiceProtocolVersion.current else { throw ServiceMessageError.incompatibleVersion(value.protocolVersion) }
        var required: Set<String> = ["protocolVersion", "requestID"]
        if stopping {
            guard value.sessionID != nil, let revision = value.revision, revision > 0 else { throw ServiceMessageError.invalid }
            required.formUnion(["sessionID", "revision"])
        } else if value.sessionID != nil { required.insert("sessionID") }
        guard Set(fields.keys) == required else { throw ServiceMessageError.invalid }
        return value
    }
}

struct NetworkSessionStart: Encodable {
    let idleToken: UUID
    let request: ConfigurationCheckRequest
    static let limit = ServiceMessages.maximumConfigurationBytes + 256
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= limit else { throw ServiceMessageError.oversized }
        do {
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(fields.keys) == ["idleToken", "request"], let token = fields["idleToken"] as? String,
                  let id = UUID(uuidString: token), let request = fields["request"] as? [String: Any] else {
                throw ServiceMessageError.invalid
            }
            let bytes = try JSONSerialization.data(withJSONObject: request, options: .withoutEscapingSlashes)
            return try Self(idleToken: id, request: ServiceMessages.decodeConfiguration(bytes))
        } catch let error as ServiceMessageError { throw error }
        catch { throw ServiceMessageError.invalid }
    }
}
