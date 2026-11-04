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
    let request = HandshakeRequest()
    let done = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>?
    let remote = connection.remoteObjectProxyWithErrorHandler { error in
        result = .failure(error)
        done.signal()
    } as! NetworkServiceProtocol
    remote.handshake(try JSONEncoder().encode(request)) { data, error in
        if let data { result = .success(data) }
        else { result = .failure(NSError(domain: "FreeV6Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: error ?? "Missing response"])) }
        done.signal()
    }
    guard done.wait(timeout: .now() + 10) == .success, let result else {
        throw NSError(domain: "FreeV6Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "XPC timed out"])
    }
    if reject {
        guard case .failure = result else { throw NSError(domain: "FreeV6Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Untrusted client was accepted"]) }
        print("PASS: untrusted XPC client rejected")
    } else {
        let reply = try JSONDecoder().decode(HandshakeReply.self, from: result.get())
        guard reply.requestID == request.requestID, reply.protocolVersion == ServiceProtocolVersion.current else {
            throw NSError(domain: "FreeV6Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Handshake mismatch"])
        }
        print("PASS: authenticated XPC handshake; privileged=\(reply.privileged)")
    }
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
    switch CommandLine.arguments.dropFirst().first {
    case "identity":
        let data = try JSONEncoder().encode(CodeIdentity.current())
        print(String(decoding: data, as: UTF8.self))
    case "xpc": try probeXPC(reject: false)
    case "xpc-reject": try probeXPC(reject: true)
    case "keychain": try probeKeychain()
    case "dns":
        let snapshots = try DNSConfiguration.capture()
        // Do not include resolver addresses or service names in console output.
        print("PASS: captured configured DNS for \(snapshots.count) network services; no settings changed")
    default:
        print("Usage: freev6-probe identity|xpc|xpc-reject|dns|keychain")
        exit(2)
    }
} catch {
    fputs("freev6-probe: \(error.localizedDescription)\n", stderr)
    exit(1)
}
