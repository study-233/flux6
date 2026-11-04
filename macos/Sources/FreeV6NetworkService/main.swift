import Foundation
import FreeV6System

final class ServiceSession: NSObject, NetworkServiceProtocol {
    func handshake(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let request = try ServiceMessages.decodeHandshake(data)
            let response = HandshakeReply(requestID: request.requestID, serviceVersion: "0.5.2-p0", privileged: geteuid() == 0)
            reply(try JSONEncoder().encode(response), nil)
        } catch { reply(nil, error.localizedDescription) }
    }
}

final class ServiceListener: NSObject, NSXPCListenerDelegate {
    private let registration: ServiceRegistration
    init(registration: ServiceRegistration) { self.registration = registration }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = registration.requirement(for: connection.effectiveUserIdentifier) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetworkServiceProtocol.self)
        connection.exportedObject = ServiceSession()
        connection.resume()
        return true
    }
}

do {
    var serviceName = ServiceProtocolVersion.machService
    var registrationPath = ServicePaths.registration
    var owner: uid_t = 0
    let arguments = Array(CommandLine.arguments.dropFirst())
    if !arguments.isEmpty {
        #if DEBUG
        guard arguments.count == 3, arguments[0] == "--probe",
              arguments[1].hasPrefix("dev.freev6.probe."),
              arguments[1].utf8.count <= 128, geteuid() != 0 else {
            throw NSError(domain: "FreeV6Service", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid probe arguments"])
        }
        serviceName = arguments[1]
        registrationPath = arguments[2]
        owner = geteuid()
        #else
        throw NSError(domain: "FreeV6Service", code: 2, userInfo: [NSLocalizedDescriptionKey: "Release service does not accept arguments"])
        #endif
    } else if geteuid() != 0 {
        throw NSError(domain: "FreeV6Service", code: 3, userInfo: [NSLocalizedDescriptionKey: "Network service must be installed by an administrator"])
    }
    let registration = try RegistrationFile.load(path: registrationPath, owner: owner, service: CodeIdentity.current())
    let listener = NSXPCListener(machServiceName: serviceName)
    let delegate = ServiceListener(registration: registration)
    listener.delegate = delegate
    listener.resume()
    RunLoop.current.run()
    withExtendedLifetime(delegate) {}
} catch {
    fputs("freev6-network-service: \(error.localizedDescription)\n", stderr)
    exit(1)
}
