import Foundation
import FreeV6System

final class ServiceSession: NSObject, NetworkServiceProtocol {
    private let resources: ServiceResourceStore
    private let sessions: ServiceNetworkSessions
    private let clientUID: uid_t
    init(resources: ServiceResourceStore, sessions: ServiceNetworkSessions, clientUID: uid_t) {
        self.resources = resources; self.sessions = sessions; self.clientUID = clientUID
    }

    func startSession(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do { reply(try JSONEncoder().encode(sessions.start(data, uid: clientUID)), nil) }
        catch { reply(nil, error.localizedDescription) }
    }

    func stopSession(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do { reply(try JSONEncoder().encode(sessions.stop(data, uid: clientUID)), nil) }
        catch { reply(nil, error.localizedDescription) }
    }

    func sessionStatus(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do { reply(try JSONEncoder().encode(sessions.status(data, uid: clientUID)), nil) }
        catch { reply(nil, error.localizedDescription) }
    }

    func handshake(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let request = try ServiceMessages.decodeHandshake(data)
            let response = HandshakeReply(requestID: request.requestID, serviceVersion: "0.5.2-p4-sessions", privileged: geteuid() == 0)
            reply(try JSONEncoder().encode(response), nil)
        } catch { reply(nil, error.localizedDescription) }
    }

    func resourceStatus(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let request = try ServiceMessages.decodeResource(data, installing: false)
            reply(try JSONEncoder().encode(ResourceReply(requestID: request.requestID, resources: resources.status())), nil)
        } catch { reply(nil, error.localizedDescription) }
    }

    func installApprovedResource(_ data: Data, source: FileHandle, reply: @escaping (Data?, String?) -> Void) {
        defer { try? source.close() }
        do {
            let request = try ServiceMessages.decodeResource(data, installing: true)
            let installed = try resources.install(id: request.resourceID!, source: source, clientUID: clientUID)
            reply(try JSONEncoder().encode(ResourceReply(requestID: request.requestID, resources: [installed])), nil)
        } catch { reply(nil, error.localizedDescription) }
    }

    func checkConfiguration(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do { reply(try JSONEncoder().encode(resources.checkConfiguration(data, clientUID: clientUID)), nil) }
        catch { reply(nil, error.localizedDescription) }
    }
}

final class ServiceListener: NSObject, NSXPCListenerDelegate {
    private let registration: ServiceRegistration
    private let resources: ServiceResourceStore
    private let sessions: ServiceNetworkSessions
    init(registration: ServiceRegistration, resources: ServiceResourceStore, sessions: ServiceNetworkSessions) {
        self.registration = registration; self.resources = resources; self.sessions = sessions
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = registration.requirement(for: connection.effectiveUserIdentifier) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
        connection.exportedObject = ServiceSession(resources: resources, sessions: sessions, clientUID: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

do {
    var serviceName = ServiceProtocolVersion.machService
    var registrationPath = ServicePaths.registration
    var owner: uid_t = 0
    var resourcesPath = ServicePaths.resources
    let arguments = Array(CommandLine.arguments.dropFirst())
    if !arguments.isEmpty {
        #if DEBUG
        guard arguments.count == 3, ["--probe", "--probe-run"].contains(arguments[0]),
              arguments[1].hasPrefix("dev.freev6.probe."),
              arguments[1].utf8.count <= 128, geteuid() != 0 else {
            throw NSError(domain: "FreeV6Service", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid probe arguments"])
        }
        serviceName = arguments[1]
        registrationPath = arguments[2]
        resourcesPath = URL(fileURLWithPath: registrationPath).deletingLastPathComponent().appendingPathComponent("resources").path
        owner = geteuid()
        #else
        throw NSError(domain: "FreeV6Service", code: 2, userInfo: [NSLocalizedDescriptionKey: "Release service does not accept arguments"])
        #endif
    } else if geteuid() != 0 {
        throw NSError(domain: "FreeV6Service", code: 3, userInfo: [NSLocalizedDescriptionKey: "Network service must be installed by an administrator"])
    }
    let registration = try RegistrationFile.load(path: registrationPath, owner: owner, service: CodeIdentity.current())
    let listener = NSXPCListener(machServiceName: serviceName)
    let resources = try ServiceResourceStore(path: resourcesPath, owner: owner)
    let sessions = ServiceNetworkSessions(resources: resources, restartAfterUncertainLaunch: { exit(EX_TEMPFAIL) })
    #if DEBUG
    if arguments.first == "--probe-run" { try sessions.useIsolatedNetwork() }
    #endif
    let delegate = ServiceListener(registration: registration, resources: resources, sessions: sessions)
    listener.delegate = delegate
    listener.resume()
    RunLoop.current.run()
    withExtendedLifetime(delegate) {}
} catch {
    fputs("freev6-network-service: \(error.localizedDescription)\n", stderr)
    exit(1)
}
