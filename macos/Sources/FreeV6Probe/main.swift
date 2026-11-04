import Foundation
import Security
import FreeV6System

final class ProbeService: NSObject, NetworkServiceProtocol {
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

    func wait() throws -> Data {
        guard done.wait(timeout: .now() + 10) == .success else {
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
    case "dns":
        let snapshots = try DNSConfiguration.capture()
        // Do not include resolver addresses or service names in console output.
        print("PASS: captured configured DNS for \(snapshots.count) network services; no settings changed")
    default:
        print("Usage: freev6-probe identity [path]|registration <service>|mach <probe-name> <hash>|xpc|xpc-reject|dns|keychain")
        exit(2)
    }
} catch {
    let detail = error as NSError
    fputs("freev6-probe: \(detail.domain) \(detail.code): \(detail.localizedDescription)\n", stderr)
    exit(1)
}
