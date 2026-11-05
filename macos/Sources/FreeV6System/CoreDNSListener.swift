import Darwin
import Foundation
import Network

enum CoreDNSListener {
    // lsof's machine-readable records identify the listening process. The
    // session-specific .test name is answered from the core's local hosts.
    static func waitUntilReady(port: Int, sessionID: UUID, currentPID: () throws -> pid_t?) throws {
        guard let pid = try currentPID() else { throw SessionDNSError.resolverUnavailable }
        // The controller can accept requests before both DNS sockets answer.
        // Only retry readiness while the same launchd-owned process is alive.
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while true {
            guard try currentPID() == pid else { throw SessionDNSError.resolverUnavailable }
            do { try verify(pid: pid, port: port, sessionID: sessionID) }
            catch SessionDNSError.resolverUnavailable where ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.15)
                continue
            }
            guard try currentPID() == pid else { throw SessionDNSError.resolverUnavailable }
            return
        }
    }

    static func verify(pid: pid_t, port: Int, sessionID: UUID) throws {
        guard pid > 1, (1...65535).contains(port) else { throw SessionDNSError.resolverUnavailable }
        let result = try CapturedCommand.run(executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-FpfPnT", "-iTCP:\(port)", "-iUDP:\(port)"], timeout: 5, limit: 262_144)
        guard result.exit == .exited(0), let text = String(data: result.output, encoding: .utf8),
              ownsListeners(text, pid: pid, port: port) else { throw SessionDNSError.resolverUnavailable }
        for tcp in [false, true] {
            guard DNSCanary.query(port: UInt16(port), session: sessionID, tcp: tcp) else {
                throw SessionDNSError.resolverUnavailable
            }
        }
    }

    static func ownsListeners(_ text: String, pid: pid_t, port: Int) -> Bool {
        guard text.hasSuffix("\n") else { return false }
        var inFile = false
        var owner: pid_t?
        var transport = "", name = "", state = ""
        var tcp = false, udp = false
        func acceptFile() -> Bool {
            guard inFile else { return true }
            guard !name.isEmpty, ["TCP", "UDP"].contains(transport) else { return false }
            let local = name.components(separatedBy: "->")[0]
            guard local.hasSuffix(":\(port)") else { return true }
            if transport == "TCP", state != "LISTEN" { return !state.isEmpty && name.contains("->") }
            guard owner == pid, name == "127.0.0.1:\(port)" else { return false }
            if transport == "TCP" { tcp = true }
            else if transport == "UDP" { udp = true }
            else { return false }
            return true
        }
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p", "f":
                guard acceptFile() else { return false }
                transport = ""; name = ""; state = ""
                inFile = line.first == "f"
                if inFile, owner == nil || value.isEmpty { return false }
                if line.first == "p" {
                    guard let parsed = pid_t(value), parsed > 0 else { return false }
                    owner = parsed
                }
            case "P": transport = value
            case "n": name = value
            case "T" where value.hasPrefix("ST="): state = String(value.dropFirst(3))
            case "T": break
            default: return false
            }
        }
        return acceptFile() && tcp && udp
    }
}

private enum DNSCanary {
    private final class Response: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var bytes: Data?
        func finish(_ value: Data?) { bytes = value; done.signal() }
    }

    static func query(port: UInt16, session: UUID, tcp: Bool) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let id = UInt16.random(in: .min ... .max)
        var question = [UInt8]()
        for label in DNSResolverPolicy.freshName(session).split(separator: ".") {
            question.append(UInt8(label.utf8.count))
            question.append(contentsOf: label.utf8)
        }
        question += [0, 0, 1, 0, 1] // end of name, A, IN
        let packet = [UInt8(id >> 8), UInt8(truncatingIfNeeded: id), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0] + question
        let wire = tcp ? [UInt8(packet.count >> 8), UInt8(truncatingIfNeeded: packet.count)] + packet : packet
        let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: tcp ? .tcp : .udp)
        let response = Response()
        connection.start(queue: DispatchQueue(label: "dev.freev6.dns-check"))
        defer { connection.cancel() }
        connection.send(content: Data(wire), completion: .contentProcessed { error in
            guard error == nil else { response.finish(nil); return }
            if tcp {
                connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { prefix, _, _, error in
                    guard error == nil, let prefix, prefix.count == 2 else { response.finish(nil); return }
                    let length = prefix.reduce(0) { $0 * 256 + Int($1) }
                    guard (12...4096).contains(length) else { response.finish(nil); return }
                    connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                        response.finish(error == nil && data?.count == length ? data : nil)
                    }
                }
            } else {
                connection.receiveMessage { data, _, complete, error in response.finish(complete && error == nil ? data : nil) }
            }
        })
        guard response.done.wait(timeout: .now() + 2) == .success, let data = response.bytes, data.count <= 4096 else { return false }
        let bytes = Array(data)
        let end = 12 + question.count
        guard bytes.count >= end + 16, bytes[0...1].elementsEqual(packet[0...1]),
              bytes[2] & 0xfa == 0x80, bytes[3] & 0x0f == 0, bytes[4...5].elementsEqual([0, 1]),
              bytes[6] != 0 || bytes[7] != 0, bytes[12..<end].elementsEqual(question) else { return false }
        let name = question.dropLast(4)
        let rr: Int
        if bytes[end..<(end + 2)].elementsEqual([0xc0, 0x0c]) { rr = end + 2 }
        else if bytes.dropFirst(end).starts(with: name) { rr = end + name.count }
        else { return false }
        guard bytes.count >= rr + 14 else { return false }
        return bytes[rr..<(rr + 4)].elementsEqual([0, 1, 0, 1])
            && bytes[(rr + 8)..<(rr + 14)].elementsEqual([0, 4, 192, 0, 2, 1])
    }
}
