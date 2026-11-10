import Foundation

public struct SessionControlTarget: Codable, Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let revision: UInt64
    public init(sessionID: UUID, revision: UInt64) {
        self.sessionID = sessionID
        self.revision = revision
    }
}

public enum SessionNodeGroup: String, CaseIterable, Codable, Sendable {
    case access, chain
    var coreName: String { self == .access ? "♻️ 自动选择" : "🔗 链式代理" }
    public var title: String { self == .access ? "接入点" : "链式代理" }
}

public enum SessionControlAction: String, Codable, Sendable { case inspect, setMode, select, unpin, delay, traffic, download, cancelDownload }

public struct SessionControlRequest: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let target: SessionControlTarget
    public let action: SessionControlAction
    public let token: UUID?
    public let mode: CoreMode?
    public let group: SessionNodeGroup?
    public let member: String?

    public init(_ target: SessionControlTarget, _ action: SessionControlAction, token: UUID? = nil,
                mode: CoreMode? = nil, group: SessionNodeGroup? = nil, member: String? = nil) {
        self.protocolVersion = ServiceProtocolVersion.current
        self.requestID = UUID()
        self.target = target
        self.action = action
        self.token = token
        self.mode = mode
        self.group = group
        self.member = member
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 else { throw ServiceMessageError.oversized }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = fields["target"] as? [String: Any], Set(target.keys) == ["sessionID", "revision"] else {
            throw ServiceMessageError.invalid
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.protocolVersion == ServiceProtocolVersion.current, value.target.revision > 0 else { throw ServiceMessageError.invalid }
        var required: Set<String> = ["protocolVersion", "requestID", "target", "action"]
        switch value.action {
        case .inspect, .traffic: break
        case .unpin, .cancelDownload:
            guard value.token != nil else { throw ServiceMessageError.invalid }
            required.insert("token")
        case .setMode:
            guard value.token != nil, value.mode != nil else { throw ServiceMessageError.invalid }
            required.formUnion(["mode", "token"])
        case .select, .delay, .download:
            guard value.group != nil, let name = value.member, CoreController.validName(name) else { throw ServiceMessageError.invalid }
            required.formUnion(["group", "member"])
            if value.action == .select {
                guard value.token != nil else { throw ServiceMessageError.invalid }
                required.insert("token")
            }
        }
        guard Set(fields.keys) == required else { throw ServiceMessageError.invalid }
        return value
    }
}

public struct SessionNodeList: Codable, Equatable, Sendable {
    public let group: SessionNodeGroup
    public let selected: String?
    public let preferred: String?
    public let automatic: Bool
    public let members: [String]
}

public struct SessionControlSnapshot: Codable, Equatable, Sendable {
    public let token: UUID
    public let mode: CoreMode
    public let groups: [SessionNodeList]

    func validate() throws {
        guard groups.count <= SessionNodeGroup.allCases.count, Set(groups.map(\.group)).count == groups.count else {
            throw ServiceClientError.invalidReply
        }
        for group in groups {
            guard (1...(group.group == .access ? 200 : 64)).contains(group.members.count), Set(group.members).count == group.members.count,
                  group.preferred.map(group.members.contains) ?? true, group.members.allSatisfy(CoreController.validName), group.selected.map(group.members.contains) ?? true else {
                throw ServiceClientError.invalidReply
            }
        }
    }
}

public struct SessionControlReply: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let target: SessionControlTarget
    public let action: SessionControlAction
    public let state: SessionControlSnapshot?
    public let traffic: CoreTrafficSample?
    public let delay: CoreDelay?
    public let download: CoreDownloadResult?
    public let cancelled: Bool?

    init(_ request: SessionControlRequest, state: SessionControlSnapshot? = nil, traffic: CoreTrafficSample? = nil, delay: CoreDelay? = nil, download: CoreDownloadResult? = nil, cancelled: Bool? = nil) {
        protocolVersion = ServiceProtocolVersion.current
        requestID = request.requestID
        target = request.target
        action = request.action
        self.state = state
        self.traffic = traffic
        self.delay = delay
        self.download = download
        self.cancelled = cancelled
    }

    package static func decode(_ data: Data, for request: SessionControlRequest) throws -> Self {
        guard data.count <= 64 * 1024, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceClientError.invalidReply
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.protocolVersion == ServiceProtocolVersion.current, value.requestID == request.requestID,
              value.target == request.target, value.action == request.action else { throw ServiceClientError.invalidReply }
        let payload: String
        switch request.action {
        case .inspect, .setMode, .select, .unpin:
            payload = "state"
            guard let state = value.state else { throw ServiceClientError.invalidReply }
            try state.validate()
            if request.action == .unpin {
                guard let group = state.groups.first(where: { $0.group == .access }), group.automatic,
                      group.preferred == nil else { throw CoreControllerError.unconfirmed }
            }
            if request.action == .setMode, state.mode != request.mode { throw CoreControllerError.unconfirmed }
            if request.action == .select, state.groups.first(where: { $0.group == request.group })?.selected != request.member {
                throw CoreControllerError.unconfirmed
            }
        case .download:
            payload = "download"
            guard let download = value.download else { throw ServiceClientError.invalidReply }
            try download.validate()
        case .cancelDownload:
            payload = "cancelled"
            guard value.cancelled == true else { throw ServiceClientError.invalidReply }
        case .traffic:
            payload = "traffic"
            guard value.traffic != nil else { throw ServiceClientError.invalidReply }
        case .delay:
            payload = "delay"
            guard let delay = value.delay else { throw ServiceClientError.invalidReply }
            if case .measured(let ms) = delay, !(1...65535).contains(ms) { throw ServiceClientError.invalidReply }
        }
        guard Set(fields.keys) == ["protocolVersion", "requestID", "target", "action", payload] else { throw ServiceClientError.invalidReply }
        return value
    }
}
