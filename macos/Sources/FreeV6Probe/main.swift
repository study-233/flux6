import Foundation
import Security
import FreeV6System
import FreeV6Configuration
#if DEBUG
import FreeV6Desktop
#endif

final class ProbeService: NSObject, NetworkServiceProtocol {
    func controlSession(_ request: Data, reply: @escaping (Data?, String?) -> Void) { reply(nil, "Handshake-only probe") }
    func startSession(_ request: Data, reply: @escaping (Data?, String?) -> Void) { reply(nil, "Handshake-only probe") }
    func stopSession(_ request: Data, reply: @escaping (Data?, String?) -> Void) { reply(nil, "Handshake-only probe") }
    func sessionStatus(_ request: Data, reply: @escaping (Data?, String?) -> Void) { reply(nil, "Handshake-only probe") }
    func checkConfiguration(_ request: Data, reply: @escaping (Data?, String?) -> Void) { reply(nil, "Handshake-only probe") }
    func resourceStatus(_ request: Data, reply: @escaping (Data?, String?) -> Void) { reply(nil, "Handshake-only probe") }
    func installApprovedResource(_ request: Data, source: FileHandle, reply: @escaping (Data?, String?) -> Void) {
        try? source.close(); reply(nil, "Handshake-only probe")
    }
    func handshake(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let request = try ServiceMessages.decodeHandshake(data)
            let response = HandshakeReply(requestID: request.requestID, serviceVersion: "p0", privileged: geteuid() == 0)
            reply(try JSONEncoder().encode(response), nil)
        } catch { reply(nil, error.localizedDescription) }
    }
}

final class ProbeListener: NSObject, NSXPCListenerDelegate {
    let requirement: String
    let service = ProbeService()
    var connections: [NSXPCConnection] = []

    init(requirement: String) { self.requirement = requirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
        connection.exportedObject = service
        connections.append(connection)
        connection.resume()
        return true
    }
}

final class HandshakeCompletion {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Data, Error>?

    func complete(_ value: Result<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        done.signal()
    }

    func wait(timeout: TimeInterval = 10) throws -> Data {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "FreeV6Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "XPC timed out"])
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

func exchangeHandshake(_ connection: NSXPCConnection) throws -> HandshakeReply {
    let request = HandshakeRequest()
    let completion = HandshakeCompletion()
    guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
        completion.complete(.failure(error))
    }) as? NetworkServiceProtocol else {
        throw NSError(domain: "FreeV6Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing XPC proxy"])
    }
    remote.handshake(try JSONEncoder().encode(request)) { data, error in
        if let data { completion.complete(.success(data)) }
        else {
            completion.complete(.failure(NSError(domain: "FreeV6Probe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: error ?? "Missing response"])))
        }
    }
    let data = try completion.wait()
    guard data.count <= ServiceMessages.maximumHandshakeBytes else { throw ServiceMessageError.oversized }
    let reply = try JSONDecoder().decode(HandshakeReply.self, from: data)
    guard reply.requestID == request.requestID, reply.protocolVersion == ServiceProtocolVersion.current else {
        throw NSError(domain: "FreeV6Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Handshake mismatch"])
    }
    return reply
}

func probeXPC(reject: Bool) throws {
    let identity = try CodeIdentity.current()
    let listener = NSXPCListener.anonymous()
    let delegate = ProbeListener(requirement: reject ? "cdhash H\"0000000000000000000000000000000000000000\"" : identity.requirement)
    listener.delegate = delegate
    listener.resume()
    defer {
        delegate.connections.forEach { $0.invalidate() }
        listener.invalidate()
    }
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.setCodeSigningRequirement(identity.requirement)
    connection.remoteObjectInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
    connection.resume()
    defer { connection.invalidate() }
    let result = Result { try exchangeHandshake(connection) }
    if reject {
        guard case .failure(let error) = result, (error as NSError).domain == NSCocoaErrorDomain else {
            throw NSError(domain: "FreeV6Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected XPC identity rejection"])
        }
        print("PASS: untrusted XPC client rejected")
    } else {
        let reply = try result.get()
        print("PASS: authenticated XPC handshake; privileged=\(reply.privileged)")
    }
}

func probeMach(name: String, hash: String) throws {
    guard name.hasPrefix("dev.freev6.probe."), name.utf8.count <= 128 else {
        throw NSError(domain: "FreeV6Probe", code: 6, userInfo: [NSLocalizedDescriptionKey: "Expected isolated probe service"])
    }
    let identity = try CodeIdentity(identifier: "probe-service", cdHash: hash)
    let reply = try ServiceClient.handshake(identity: identity, name: name, privileged: false)
    print("PASS: separate Mach service authenticated; privileged=false; version=\(reply.serviceVersion)")
}

func probeResources(name: String, hash: String, install: (String, String)? = nil) throws {
    guard geteuid() != 0, name.hasPrefix("dev.freev6.probe."), name.utf8.count <= 128 else {
        throw ServiceMessageError.invalid
    }
    let identity = try CodeIdentity(identifier: "probe-service", cdHash: hash)
    if let (id, path) = install {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResourceStoreError.invalidSource }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try ServiceClient.installResource(id: id, source: handle, identity: identity, name: name, privileged: false)
    }
    let resources = try ServiceClient.resources(identity: identity, name: name, privileged: false)
    print(String(decoding: try JSONEncoder().encode(resources), as: UTF8.self))
}

func readConfigurationRequest(_ path: String) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let data = try handle.read(upToCount: ServiceMessages.maximumConfigurationBytes + 1) ?? Data()
    guard data.count <= ServiceMessages.maximumConfigurationBytes else { throw ServiceMessageError.oversized }
    return data
}

func probeConfiguration(name: String, hash: String, path: String, cache: String? = nil) throws {
    guard geteuid() != 0, name.hasPrefix("dev.freev6.probe."), name.utf8.count <= 128 else { throw ServiceMessageError.invalid }
    let identity = try CodeIdentity(identifier: "probe-service", cdHash: hash)
    let payload = try readConfigurationRequest(path)
    if let cache {
        let request = try ServiceMessages.decodeConfiguration(payload)
        try ServiceResourceTransfer.prepare(cache: URL(fileURLWithPath: cache), runtimeID: request.runtimeID,
                                            geodataID: request.geodataID, identity: identity, name: name, privileged: false)
        let result = try ServiceClient.checkConfiguration(request, identity: identity, name: name, privileged: false)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        return
    }
    // Send raw bytes for server-side rejection tests, without client decoding.
    let connection = NSXPCConnection(machServiceName: name)
    connection.setCodeSigningRequirement(identity.requirement)
    connection.remoteObjectInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
    connection.resume()
    defer { connection.invalidate() }
    let completion = HandshakeCompletion()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ completion.complete(.failure($0)) }) as? NetworkServiceProtocol else {
        throw ServiceClientError.unavailable
    }
    proxy.checkConfiguration(payload) { data, error in
        if let data { completion.complete(.success(data)) }
        else { completion.complete(.failure(ServiceClientError.rejected(error ?? "Missing response"))) }
    }
    print(String(decoding: try completion.wait(timeout: 180), as: UTF8.self))
}

#if DEBUG
@MainActor func probeDesktopControls(target: SessionControlTarget, identity: CodeIdentity, name: String) async throws {
    guard let preferences = UserDefaults(suiteName: name) else { throw ServiceMessageError.invalid }
    defer { preferences.removePersistentDomain(forName: name) }
    let controls = DesktopCoreControls(defaults: preferences)
    let exchange: DesktopCoreControls.Exchange = { query in
        try await Task.detached { try ServiceClient.control(query, identity: identity, name: name, privileged: false) }.value
    }
    controls.bind(target)
    await controls.inspect(using: exchange)
    guard let initial = controls.state, initial.mode == .direct, initial.groups.count == 2 else {
        throw ServiceClientError.rejected(controls.error ?? "initial controls")
    }
    let mutation = SessionControlRequest(target, .setMode, token: initial.token, mode: .rule)
    guard await controls.change(mutation, using: exchange), let rule = controls.state,
          rule.mode == .rule, rule.token != initial.token else { throw ServiceClientError.rejected(controls.error ?? "mode") }
    do {
        _ = try await exchange(mutation)
        throw ServiceMessageError.invalid
    } catch ServiceClientError.rejected {}
    for group in SessionNodeGroup.allCases {
        guard let state = controls.state, let list = state.groups.first(where: { $0.group == group }),
              let member = list.members.first(where: { $0 != list.selected && (group == .chain || $0 != "REJECT") }) else { throw ServiceMessageError.invalid }
        guard await controls.change(SessionControlRequest(target, .select, token: state.token, group: group, member: member), using: exchange),
              controls.state?.groups.first(where: { $0.group == group })?.selected == member,
              controls.recentMembers(group) == [member] else { throw ServiceClientError.rejected("select " + group.rawValue + ": " + (controls.error ?? "unexpected selection")) }
    }
    guard let before = controls.state, let access = before.groups.first(where: { $0.group == .access }),
          access.preferred != nil else { throw ServiceMessageError.invalid }
    let unreachable = SessionControlRequest(target, .select, token: before.token, group: .access, member: "REJECT")
    guard !(await controls.change(unreachable, using: exchange)), let recovered = controls.state,
          recovered.groups.first(where: { $0.group == .access }) == access else {
        throw ServiceClientError.rejected("unreachable access node changed the effective or preferred route")
    }
    guard await controls.change(SessionControlRequest(target, .unpin, token: recovered.token), using: exchange),
          controls.preferredMember(.access) == nil, !controls.recentMembers(.access).isEmpty else {
        throw ServiceClientError.rejected(controls.error ?? "unpin")
    }
    await controls.measure(.access, members: ["REJECT"], using: exchange)
    guard controls.latency[.access]?["REJECT"] == .unavailable else { throw ServiceClientError.rejected(controls.error ?? "delay") }
    await controls.sample(using: exchange)
    guard controls.currentTraffic != nil, controls.history.count == 1 else { throw ServiceClientError.rejected(controls.trafficError ?? "sample") }
    for invalid in [SessionControlRequest(SessionControlTarget(sessionID: UUID(), revision: target.revision), .inspect),
                    SessionControlRequest(SessionControlTarget(sessionID: target.sessionID, revision: target.revision + 1), .traffic),
                    SessionControlRequest(target, .delay, group: .access, member: "GLOBAL")] {
        do { _ = try await exchange(invalid); throw ServiceMessageError.invalid }
        catch ServiceClientError.rejected {}
    }
    controls.bind(nil)
    guard controls.currentTraffic == nil, controls.state == nil, controls.history.isEmpty else { throw ServiceMessageError.invalid }
}

@MainActor func probeDesktopSession(_ args: [String]) async throws {
    guard args.count == 4, geteuid() != 0, args[1].hasPrefix("dev.freev6.probe."),
          args[1].utf8.count <= 128 else { throw ServiceMessageError.invalid }
    let name = args[1]
    let identity = try CodeIdentity(identifier: "probe-service", cdHash: args[2])
    let request = try ServiceMessages.decodeConfiguration(readConfigurationRequest(args[3]))
    let desktop = DesktopNetworkSession()
    let status: DesktopNetworkSession.Status = { id in
        try await Task.detached { try ServiceClient.sessionStatus(renewing: id, identity: identity, name: name, privileged: false) }.value
    }
    let stop: DesktopNetworkSession.Stop = { id, revision in
        try await Task.detached { try ServiceClient.stopSession(sessionID: id, revision: revision, identity: identity,
                                                                 name: name, privileged: false) }.value
    }
    await desktop.refresh(using: status)
    for quit in [false, true] {
        guard desktop.phase == .idle else { throw ServiceClientError.invalidReply }
        await desktop.connect { token in
            try await Task.detached { try ServiceClient.startSession(request, idleToken: token, identity: identity,
                                                                      name: name, privileged: false) }.value
        }
        if let error = desktop.error { throw ServiceClientError.rejected(error) }
        await desktop.refresh(using: status)
        var commands = DesktopCommandState()
        commands.service = .ready
        commands.network = desktop.phase
        commands.canTargetSession = desktop.canTargetSession
        guard commands.primaryCommand == .disconnect, commands.availability(.disconnect).enabled else {
            throw ServiceClientError.invalidReply
        }
        if !quit {
            guard let target = desktop.runningTarget else { throw ServiceMessageError.invalid }
            try await probeDesktopControls(target: target, identity: identity, name: name)
        }
        if quit { try await desktop.disconnectBeforeExit(status: status, stop: stop) }
        else { try await desktop.disconnect(using: stop) }
        guard desktop.phase == .idle, !desktop.mayOwnSession, desktop.error == nil else { throw ServiceClientError.invalidReply }
    }
}

func probeSessionRPC(_ args: [String]) throws {
    guard args.count >= 3, geteuid() != 0, args[1].hasPrefix("dev.freev6.probe."), args[1].utf8.count <= 128 else {
        throw ServiceMessageError.invalid
    }
    let identity = try CodeIdentity(identifier: "probe-service", cdHash: args[2])
    let reply: NetworkSessionReply
    switch args[0] {
    case "session-status" where args.count == 3 || args.count == 4:
        let id = args.count == 4 ? UUID(uuidString: args[3]) : nil
        guard args.count == 3 || id != nil else { throw ServiceMessageError.invalid }
        reply = try ServiceClient.sessionStatus(renewing: id, identity: identity, name: args[1], privileged: false)
    case "session-start" where args.count == 5:
        guard let token = UUID(uuidString: args[3]) else { throw ServiceMessageError.invalid }
        let request = try ServiceMessages.decodeConfiguration(readConfigurationRequest(args[4]))
        reply = try ServiceClient.startSession(request, idleToken: token, identity: identity, name: args[1], privileged: false)
    case "session-stop" where args.count == 5:
        guard let id = UUID(uuidString: args[3]), let revision = UInt64(args[4]) else { throw ServiceMessageError.invalid }
        reply = try ServiceClient.stopSession(sessionID: id, revision: revision, identity: identity, name: args[1], privileged: false)
    default: throw ServiceMessageError.invalid
    }
    print(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
}
#endif

func probeKeychain() throws {
    let account = UUID().uuidString
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.freev6.probe",
        kSecAttrAccount as String: account,
    ]
    let value = Data(UUID().uuidString.utf8)
    var insertion = query
    insertion[kSecValueData as String] = value
    let added = SecItemAdd(insertion as CFDictionary, nil)
    guard added == errSecSuccess else { throw IdentityError.security(added) }
    defer { SecItemDelete(query as CFDictionary) }
    var lookup = query
    lookup[kSecReturnData as String] = true
    var result: CFTypeRef?
    let read = SecItemCopyMatching(lookup as CFDictionary, &result)
    guard read == errSecSuccess else { throw IdentityError.security(read) }
    guard (result as? Data) == value else {
        throw NSError(domain: "FreeV6Probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Keychain value mismatch"])
    }
    let removed = SecItemDelete(query as CFDictionary)
    guard removed == errSecSuccess else { throw IdentityError.security(removed) }
    print("PASS: temporary Keychain round trip; test item removed")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "identity":
        let identity = try arguments.count == 2 ? CodeIdentity.file(at: URL(fileURLWithPath: arguments[1])) : CodeIdentity.current()
        let data = try JSONEncoder().encode(identity)
        print(String(decoding: data, as: UTF8.self))
    case "registration" where arguments.count == 2:
        let registration = try ServiceRegistration(service: CodeIdentity.file(at: URL(fileURLWithPath: arguments[1])),
            clients: [RegisteredClient(uid: geteuid(), identity: CodeIdentity.current())])
        let data = try JSONEncoder().encode(registration)
        print(String(decoding: data, as: UTF8.self))
    case "mach" where arguments.count == 3:
        try probeMach(name: arguments[1], hash: arguments[2])
    case "resources" where arguments.count == 3:
        try probeResources(name: arguments[1], hash: arguments[2])
    case "install-resource" where arguments.count == 5:
        try probeResources(name: arguments[1], hash: arguments[2], install: (arguments[3], arguments[4]))
    case "check-configuration" where arguments.count == 4:
        try probeConfiguration(name: arguments[1], hash: arguments[2], path: arguments[3])
    case "prepare-configuration" where arguments.count == 5:
        try probeConfiguration(name: arguments[1], hash: arguments[2], path: arguments[4], cache: arguments[3])
    case "assemble-configuration" where arguments.count == 3:
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        let request = try ServiceMessages.decodeConfiguration(readConfigurationRequest(arguments[1]))
        let assembled = try ServiceConfigurationAssembler.assemble(request.configuration, sessionID: UUID())
        try assembled.data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        print("PASS: service policy assembled for a local configuration probe; no network changes")
    #if DEBUG
    case "desktop-session" where arguments.count == 4:
        Task { @MainActor in
            do { try await probeDesktopSession(arguments); exit(0) }
            catch { fputs("desktop session: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        dispatchMain()
    case "session-status", "session-start", "session-stop": try probeSessionRPC(arguments)
    case "probe-network-run" where arguments.count == 4:
        try NetworkRunProbe.run(path: arguments[1], request: readConfigurationRequest(arguments[2]), checkpoint: arguments[3])
        print("PASS: running core, DNS transaction and owner-bound stop completed")
    case "probe-network-recover" where arguments.count == 2:
        try NetworkRunProbe.run(path: arguments[1], request: nil, checkpoint: nil)
        print("PASS: interrupted run recovered")
    case "failed-check" where arguments.count == 4:
        try SessionPreparationProbe.failedCheck(path: arguments[1], request: readConfigurationRequest(arguments[2]), failure: arguments[3])
        print("PASS: failed core check stopped and removed job, private configuration and journal")
    case "hold-check" where arguments.count == 4:
        try SessionPreparationProbe.holdCheck(path: arguments[1], request: readConfigurationRequest(arguments[2]), checkpoint: arguments[3])
    case "recover-check" where arguments.count == 2:
        try SessionPreparationProbe.recoverCheck(path: arguments[1])
        print("PASS: configuration-check journal recovered and cleared")
    case "core-job" where arguments.count == 4:
        guard let sessionID = UUID(uuidString: arguments[2]) else { throw ServiceMessageError.invalid }
        try CoreJobProbe.run(action: arguments[1], sessionID: sessionID, path: arguments[3])
    case "core-controller" where arguments.count == 3:
        guard let pid = pid_t(arguments[2]) else { throw ServiceMessageError.invalid }
        try CoreControllerProbe.run(path: arguments[1], pid: pid)
    case "hold-group" where arguments.count == 3:
        try SessionPreparationProbe.holdGroup(executable: arguments[1], directory: arguments[2])
    case "hold-session" where arguments.count == 3, "hold-partial-session" where arguments.count == 3:
        try SessionPreparationProbe.hold(path: arguments[1], request: readConfigurationRequest(arguments[2]),
            partial: arguments[0] == "hold-partial-session")
    case "recover-session" where arguments.count == 2:
        try SessionPreparationProbe.recover(path: arguments[1])
        print("PASS: preparation recovered; no process or network changes")
    #endif
    case "payload" where arguments.count == 4:
        guard geteuid() != 0 else { throw InstallationError.invalidPayload }
        let app = URL(fileURLWithPath: arguments[1])
        let installer = app.appendingPathComponent("Contents/Helpers/freev6-service-installer")
        let client = try CodeIdentity.protectedFile(at: app, identifier: "dev.freev6.desktop")
        let bootstrap = try CodeIdentity.protectedFile(at: installer, identifier: "dev.freev6.service-installer")
        _ = try InstallationPayload.prepare(app: app, clientHash: client.cdHash, uid: geteuid(), serviceHash: arguments[3],
            installer: installer, installerIdentity: bootstrap, stagingPath: arguments[2], owner: geteuid())
        print("PASS: signed installation payload staged and verified without root installation")
    case "xpc": try probeXPC(reject: false)
    case "xpc-reject": try probeXPC(reject: true)
    case "keychain": try probeKeychain()
    case "dns-targets":
        let preview = try DNSConfiguration.previewTargets()
        print("Eligible physical primary services: \(preview.count); DNS endpoint in published configuration: \(preview.endpointInUse)")
    case "dns":
        let snapshots = try DNSConfiguration.capture()
        // Do not include resolver addresses or service names in console output.
        print("PASS: captured configured DNS for \(snapshots.count) network services; no settings changed")
    default:
        print("Usage: freev6-probe identity [path]|registration <service>|mach <probe-name> <hash>|xpc|xpc-reject|dns|dns-targets|keychain")
        exit(2)
    }
} catch {
    let detail = error as NSError
    fputs("freev6-probe: \(detail.domain) \(detail.code): \(detail.localizedDescription)\n", stderr)
    exit(1)
}
