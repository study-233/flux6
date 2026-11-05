import Foundation

public enum ServiceClient {
    public static func checkConfiguration(_ request: ConfigurationCheckRequest, identity: CodeIdentity,
                                          name: String = ServiceProtocolVersion.machService,
                                          privileged: Bool = true) throws -> ConfigurationCheckReply {
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= ServiceMessages.maximumConfigurationBytes else { throw ServiceMessageError.oversized }
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged, timeout: 180) { proxy, reply in
            proxy.checkConfiguration(payload, reply: reply)
        }
        return try decodeConfigurationReply(data, request: request)
    }

    static func decodeConfigurationReply(_ data: Data, request: ConfigurationCheckRequest) throws -> ConfigurationCheckReply {
        guard data.count <= ServiceMessages.maximumHandshakeBytes else { throw ServiceMessageError.oversized }
        let response = try JSONDecoder().decode(ConfigurationCheckReply.self, from: data)
        guard response.protocolVersion == ServiceProtocolVersion.current, response.requestID == request.requestID,
              response.policyVersion == ServiceConfigurationAssembler.policyVersion,
              response.settingsRevision == request.settingsRevision, response.credentialRevision == request.credentialRevision,
              response.mode == request.configuration.mode, response.proxyCount == request.configuration.proxyCount,
              response.ruleCount == request.configuration.ruleCount, response.coreValidated else { throw ServiceClientError.invalidReply }
        return response
    }

    public static func control(_ query: SessionControlRequest, identity: CodeIdentity,
                               name: String = ServiceProtocolVersion.machService, privileged: Bool = true,
                               timeout: TimeInterval = 30) throws -> SessionControlReply {
        let payload = try JSONEncoder().encode(query)
        _ = try SessionControlRequest.decode(payload)
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged, timeout: timeout) { $0.controlSession(payload, reply: $1) }
        return try SessionControlReply.decode(data, for: query)
    }

    public static func sessionStatus(renewing sessionID: UUID? = nil, identity: CodeIdentity,
                                     name: String = ServiceProtocolVersion.machService, privileged: Bool = true) throws -> NetworkSessionReply {
        let query = NetworkSessionQuery(sessionID: sessionID)
        let payload = try JSONEncoder().encode(query)
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged, timeout: 6) { $0.sessionStatus(payload, reply: $1) }
        return try NetworkSessionReply.decode(data, id: query.requestID)
    }

    public static func startSession(_ request: ConfigurationCheckRequest, idleToken: UUID, identity: CodeIdentity,
                                    name: String = ServiceProtocolVersion.machService, privileged: Bool = true) throws -> NetworkSessionReply {
        let payload = try JSONEncoder().encode(NetworkSessionStart(idleToken: idleToken, request: request))
        guard payload.count <= NetworkSessionStart.limit else { throw ServiceMessageError.oversized }
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged, timeout: 180) { $0.startSession(payload, reply: $1) }
        let reply = try NetworkSessionReply.decode(data, id: request.requestID)
        guard reply.phase == .running, reply.credentialRevision == request.credentialRevision,
              reply.settingsRevision == request.settingsRevision else { throw ServiceClientError.invalidReply }
        return reply
    }

    public static func stopSession(sessionID: UUID, revision: UInt64, identity: CodeIdentity,
                                   name: String = ServiceProtocolVersion.machService, privileged: Bool = true) throws -> NetworkSessionReply {
        let query = NetworkSessionQuery(sessionID: sessionID, revision: revision)
        let payload = try JSONEncoder().encode(query)
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged, timeout: 60) { $0.stopSession(payload, reply: $1) }
        let reply = try NetworkSessionReply.decode(data, id: query.requestID)
        guard reply.phase == .stopped else { throw ServiceClientError.invalidReply }
        return reply
    }

    public static func resources(identity: CodeIdentity, name: String = ServiceProtocolVersion.machService,
                                 privileged: Bool = true) throws -> [ResourceAvailability] {
        let request = ResourceRequest()
        let payload = try JSONEncoder().encode(request)
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged) { proxy, reply in
            proxy.resourceStatus(payload, reply: reply)
        }
        let response = try decodeResources(data, request: request)
        guard Set(response.map(\.id)) == Set(ApprovedResourceCatalog.native.map(\.id)),
              response.count == ApprovedResourceCatalog.native.count else { throw ServiceClientError.invalidReply }
        return response
    }

    public static func installResource(id: String, source: FileHandle, identity: CodeIdentity,
                                       name: String = ServiceProtocolVersion.machService,
                                       privileged: Bool = true) throws {
        let request = ResourceRequest(resourceID: id)
        let payload = try JSONEncoder().encode(request)
        let data = try resourceExchange(identity: identity, name: name, privileged: privileged) { proxy, reply in
            proxy.installApprovedResource(payload, source: source, reply: reply)
        }
        let response = try decodeResources(data, request: request)
        guard response == [ResourceAvailability(id: id, available: true)] else { throw ServiceClientError.invalidReply }
    }

    private static func decodeResources(_ data: Data, request: ResourceRequest) throws -> [ResourceAvailability] {
        guard data.count <= ServiceMessages.maximumHandshakeBytes else { throw ServiceMessageError.oversized }
        let response = try JSONDecoder().decode(ResourceReply.self, from: data)
        guard response.protocolVersion == ServiceProtocolVersion.current, response.requestID == request.requestID else {
            throw ServiceClientError.invalidReply
        }
        return response.resources
    }

    private static func resourceExchange(identity: CodeIdentity, name: String, privileged: Bool,
                                         timeout: TimeInterval = 35,
                                         call: (NetworkServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) throws -> Data {
        let connection = NSXPCConnection(machServiceName: name, options: privileged ? .privileged : [])
        connection.setCodeSigningRequirement(identity.requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let completion = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ completion.complete(.failure($0)) }) as? NetworkServiceProtocol else {
            throw ServiceClientError.unavailable
        }
        call(proxy) { data, error in
            if let data { completion.complete(.success(data)) }
            else { completion.complete(.failure(ServiceClientError.rejected(error ?? "Missing response"))) }
        }
        return try completion.wait(timeout: timeout)
    }

    /// Blocking boundary for CLI/installers; UI callers use a background task.
    public static func handshake(identity: CodeIdentity, name: String = ServiceProtocolVersion.machService,
                                 privileged: Bool = true, timeout: TimeInterval = 10) throws -> HandshakeReply {
        let connection = NSXPCConnection(machServiceName: name, options: privileged ? .privileged : [])
        connection.setCodeSigningRequirement(identity.requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let completion = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ completion.complete(.failure($0)) }) as? NetworkServiceProtocol else {
            throw ServiceClientError.unavailable
        }
        let request = HandshakeRequest()
        proxy.handshake(try JSONEncoder().encode(request)) { data, error in
            if let data { completion.complete(.success(data)) }
            else { completion.complete(.failure(ServiceClientError.rejected(error ?? "Missing response"))) }
        }
        let data = try completion.wait(timeout: timeout)
        guard data.count <= ServiceMessages.maximumHandshakeBytes else { throw ServiceMessageError.oversized }
        let reply = try JSONDecoder().decode(HandshakeReply.self, from: data)
        guard reply.protocolVersion == ServiceProtocolVersion.current, reply.requestID == request.requestID,
              reply.privileged == privileged else { throw ServiceClientError.invalidReply }
        return reply
    }
}

private final class ReplyBox {
    let lock = NSLock()
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>?
    func complete(_ value: Result<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        semaphore.signal()
    }
    func wait(timeout: TimeInterval) throws -> Data {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { throw ServiceClientError.timeout }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

public enum ServiceClientError: Error, LocalizedError {
    case unavailable, timeout, invalidReply, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "无法连接网络服务"
        case .timeout: return "网络服务响应超时"
        case .invalidReply: return "网络服务返回的身份或协议不符合要求"
        case .rejected(let message): return message
        }
    }
}

final class LaunchdController: ServiceControlling {
    private let target = "system/" + ServiceProtocolVersion.machService

    private func run(_ arguments: [String]) throws -> Int32 {
        let process = try OwnedChildProcess(executable: "/bin/launchctl", arguments: arguments, directory: "/")
        switch try process.runToExit(timeout: 15, gracePeriod: 2) {
        case .exited(let status): return status
        case .signaled(let signal): throw InstallationError.launchd("子进程被信号 \(signal) 终止")
        }
    }

    func isLoaded() throws -> Bool {
        let status = try run(["print", target])
        if status == 0 { return true }
        if status == 113 || status == 3 { return false }
        throw InstallationError.launchd("print (\(status))")
    }
    func stop() throws {
        guard try isLoaded() else { return }
        let status = try run(["bootout", target])
        guard status == 0 || status == 113 || status == 3 else { throw InstallationError.launchd("bootout (\(status))") }
    }
    func start(plist: String) throws {
        let status = try run(["bootstrap", "system", plist])
        guard status == 0 else { throw InstallationError.launchd("bootstrap (\(status))") }
    }
    func healthCheck(identity: CodeIdentity) throws { _ = try ServiceClient.handshake(identity: identity) }
}
