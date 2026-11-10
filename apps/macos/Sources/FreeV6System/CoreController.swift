import Darwin
import Foundation

public enum CoreMode: String, CaseIterable, Codable, Sendable { case rule, global, direct }

struct CoreProxy: Decodable, Equatable, Sendable {
    let name: String
    let type: String
    let fixed: String?
    let now: String?
    let all: [String]?
    var canSelect: Bool { ["Selector", "URLTest", "Fallback"].contains(type) && all != nil }
}

struct CoreTrafficTotals: Decodable, Equatable, Sendable {
    let uploadTotal: UInt64
    let downloadTotal: UInt64
}

public struct CoreTrafficSample: Codable, Equatable, Sendable {
    public let up: UInt64
    public let down: UInt64
    public let upTotal: UInt64
    public let downTotal: UInt64
}

public enum CoreDelay: Codable, Equatable, Sendable { case measured(milliseconds: Int), unavailable, timedOut }

/// Service-internal, restricted operations for one immutable session. The
/// caller must hold the session lease and serialize mutations/recovery. A
/// successful write is re-read before acknowledgement; a timeout never implies
/// that the write did not happen. This class does not restore DNS or stop jobs.
final class CoreController {
    private let transport: UnixControllerTransport
    private let directory: SecureDirectory
    private let currentPID: () throws -> pid_t

    init(directory: SecureDirectory, job: ManagedCoreJob) throws {
        self.directory = directory
        currentPID = {
            guard let pid = try job.status()?.pid else { throw CoreControllerError.notRunning }
            return pid
        }
        guard directory.owner == 0, geteuid() == 0,
              URL(fileURLWithPath: directory.path).lastPathComponent == job.sessionID.uuidString else {
            throw CoreControllerError.identity
        }
        transport = UnixControllerTransport(directory: directory) {
            guard let pid = try job.status()?.pid else { throw CoreControllerError.notRunning }
            return pid
        }
    }

    #if DEBUG
    init(probeDirectory: SecureDirectory, currentPID: @escaping () throws -> pid_t) throws {
        self.directory = probeDirectory
        self.currentPID = currentPID
        guard geteuid() != 0, probeDirectory.owner == geteuid() else { throw CoreControllerError.identity }
        transport = UnixControllerTransport(directory: probeDirectory, currentPID: currentPID)
    }
    #endif

    /// Only the authenticated controller is ready here. Provider loading and
    /// forwarding may still be pending; the network run must verify real egress.
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 12) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw CoreControllerError.invalidRequest }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CoreControllerError.timedOut }
            do { return try version(timeout: min(3, remaining)) }
            catch CoreControllerError.notReady {
                Thread.sleep(forTimeInterval: min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
        }
    }

    func version(timeout: TimeInterval = 3) throws -> String {
        struct Reply: Decodable { let version: String }
        let response: Reply = try decode(transport.exchange(method: "GET", target: "/version", timeout: timeout))
        guard response.version == ApprovedResourceCatalog.coreVersion else { throw CoreControllerError.wrongVersion }
        return response.version
    }

    func mode() throws -> CoreMode {
        struct Reply: Decodable { let mode: CoreMode }
        let response: Reply = try decode(transport.exchange(method: "GET", target: "/configs"))
        return response.mode
    }

    func setMode(_ mode: CoreMode) throws {
        try noContent(transport.exchange(method: "PATCH", target: "/configs", body: JSONEncoder().encode(["mode": mode.rawValue])))
        guard try self.mode() == mode else { throw CoreControllerError.unconfirmed }
    }

    func proxies() throws -> [String: CoreProxy] {
        struct Reply: Decodable { let proxies: [String: CoreProxy] }
        let reply: Reply = try decode(transport.exchange(method: "GET", target: "/proxies"))
        guard !reply.proxies.isEmpty, reply.proxies.count <= 1024 else { throw CoreControllerError.invalidResponse }
        for (name, proxy) in reply.proxies {
            guard name == proxy.name else { throw CoreControllerError.invalidResponse }
            try validate(proxy)
        }
        return reply.proxies
    }

    func select(group: String, member: String) throws {
        guard Self.validName(group), Self.validName(member) else { throw CoreControllerError.invalidRequest }
        let current = try proxy(group)
        guard current.canSelect, current.all?.contains(member) == true else { throw CoreControllerError.invalidRequest }
        try noContent(transport.exchange(method: "PUT", target: "/proxies/" + Self.escaped(group),
                                         body: JSONEncoder().encode(["name": member])))
        let readback = try proxy(group)
        guard readback.now == member else {
            // URLTest may accept a pin but continue routing over another healthy
            // node. Undo that latent preference before reporting a failed switch.
            if readback.fixed == member, group == SessionNodeGroup.access.coreName, current.type == "URLTest" {
                if let previous = current.fixed, !previous.isEmpty {
                    try noContent(transport.exchange(method: "PUT", target: "/proxies/" + Self.escaped(group),
                                                     body: JSONEncoder().encode(["name": previous])))
                    guard try proxy(group).fixed == previous else { throw CoreControllerError.unconfirmed }
                } else { try clearAccessPin() }
            }
            throw CoreControllerError.unconfirmed
        }
    }

    func clearAccessPin() throws {
        let name = SessionNodeGroup.access.coreName
        guard try proxy(name).type == "URLTest" else { throw CoreControllerError.invalidRequest }
        try noContent(transport.exchange(method: "DELETE", target: "/proxies/" + Self.escaped(name)))
        guard try proxy(name).fixed == "" else { throw CoreControllerError.unconfirmed }
    }

    func controls(token: UUID) throws -> SessionControlSnapshot {
        let proxies = try proxies()
        let groups = try SessionNodeGroup.allCases.compactMap { group -> SessionNodeList? in
            guard let proxy = proxies[group.coreName] else { return nil }
            guard proxy.canSelect, let members = proxy.all else { throw CoreControllerError.invalidResponse }
            return SessionNodeList(group: group, selected: proxy.now, preferred: proxy.fixed.flatMap { $0.isEmpty ? nil : $0 },
                                   automatic: proxy.type == "URLTest", members: members)
        }
        let result = try SessionControlSnapshot(token: token, mode: mode(), groups: groups)
        try result.validate()
        return result
    }

    func measureDelay(group: SessionNodeGroup, member: String) throws -> CoreDelay {
        let selection = try proxy(group.coreName)
        guard selection.canSelect, selection.all?.contains(member) == true else { throw CoreControllerError.invalidRequest }
        return try measureDelay(name: member)
    }

    func measureDownload(group: SessionNodeGroup, member: String, cancellation: DownloadCancellation,
                         endpoint: String = CoreDownload.endpoint, caFile: String? = nil) throws -> CoreDownloadResult {
        let selection = try proxy(group.coreName)
        guard selection.canSelect, selection.all?.contains(member) == true,
              try proxy(member).all == nil, !["DIRECT", "REJECT"].contains(member) else {
            throw CoreControllerError.invalidRequest
        }
        try cancellation.check()
        do { try select(group: CoreDownload.group, member: member) }
        catch {
            try? select(group: CoreDownload.group, member: "REJECT")
            throw error
        }
        let outcome = Result { try CoreDownload.run(directory: directory, cancellation: cancellation, endpoint: endpoint, caFile: caFile) { port in
            try CoreDNSListener.verifyTCP(pid: currentPID(), port: port)
        } }
        // A test never changes the normal access/chain selector. Disable its
        // dedicated channel when finished, including timeout and cancellation.
        try select(group: CoreDownload.group, member: "REJECT")
        return try outcome.get()
    }

    func measureDelay(name: String) throws -> CoreDelay {
        guard Self.validName(name) else { throw CoreControllerError.invalidRequest }
        _ = try proxy(name)
        // Never accept a caller-provided URL; measuring through the root core
        // must not become a generic request to a local service or arbitrary host.
        let target = "/proxies/" + Self.escaped(name) + "/delay?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
        let response = try transport.exchange(method: "GET", target: target, timeout: 7)
        if response.status == 503 { return .unavailable }
        if response.status == 504 { return .timedOut }
        struct Reply: Decodable { let delay: Int }
        let reply: Reply = try decode(response)
        guard (1...65535).contains(reply.delay) else { throw CoreControllerError.invalidResponse }
        return .measured(milliseconds: reply.delay)
    }

    func trafficTotals() throws -> CoreTrafficTotals {
        // Decode only counters; connection addresses, process metadata and
        // chains from /connections are never returned to a caller or logged.
        try decode(transport.exchange(method: "GET", target: "/connections"))
    }

    func trafficSample() throws -> CoreTrafficSample {
        // Fixed core emits its first rate/counter sample after one second.
        // This operation owns no timer or background task after returning.
        try decode(transport.exchange(method: "GET", target: "/traffic", firstTrafficSample: true))
    }

    private func proxy(_ name: String) throws -> CoreProxy {
        let proxy: CoreProxy = try decode(transport.exchange(method: "GET", target: "/proxies/" + Self.escaped(name)))
        guard proxy.name == name else { throw CoreControllerError.invalidResponse }
        try validate(proxy)
        return proxy
    }

    private func validate(_ proxy: CoreProxy) throws {
        guard Self.validName(proxy.name), Self.validName(proxy.type), proxy.type.utf8.count <= 64 else {
            throw CoreControllerError.invalidResponse
        }
        if let members = proxy.all {
            guard !members.isEmpty, members.count <= 1024, members.allSatisfy(Self.validName),
                  Set(members).count == members.count,
                  proxy.fixed.map({ $0.isEmpty || members.contains($0) }) ?? true,
                  proxy.now == nil || members.contains(proxy.now!) else { throw CoreControllerError.invalidResponse }
        } else if proxy.now != nil { throw CoreControllerError.invalidResponse }
    }

    private func decode<T: Decodable>(_ response: CoreHTTPResponse) throws -> T {
        guard response.status == 200 else { throw CoreControllerError.rejected(response.status) }
        do { return try JSONDecoder().decode(T.self, from: response.body) }
        catch { throw CoreControllerError.invalidResponse } // Never return decoder context or core error bodies.
    }

    private func noContent(_ response: CoreHTTPResponse) throws {
        guard response.status == 204 else { throw CoreControllerError.rejected(response.status) }
        guard response.body.isEmpty else { throw CoreControllerError.invalidResponse }
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func escaped(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
