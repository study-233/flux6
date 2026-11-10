#if DEBUG
import Darwin
import Foundation

/// Runs against an ordinary-user, no-network core owned by the probe script.
/// No arbitrary controller operation or probe initializer exists in Release.
public enum CoreControllerProbe {
    public static func run(path: String, pid: pid_t) throws {
        guard geteuid() != 0, pid > 1, pid != getpid() else { throw CoreControllerError.invalidRequest }
        let directory = try SecureDirectory(path: path, owner: geteuid())
        let client = try CoreController(probeDirectory: directory, currentPID: { pid })
        let version = try client.waitUntilReady()
        let wrongPeer = try CoreController(probeDirectory: directory, currentPID: { getpid() })
        do { _ = try wrongPeer.version(); throw CoreControllerError.unconfirmed }
        catch CoreControllerError.identity { }
        guard try client.mode() == .direct else { throw CoreControllerError.unconfirmed }
        for mode in [CoreMode.rule, .global, .direct] { try client.setMode(mode) }
        let proxies = try client.proxies()
        let groups = ["选择 / 50%", "literal%2F?&"]
        for name in groups {
            guard proxies[name]?.all == ["DIRECT", "REJECT"] else { throw CoreControllerError.invalidResponse }
            try client.select(group: name, member: "REJECT")
            try client.select(group: name, member: "DIRECT")
            do { try client.select(group: name, member: "not-a-member"); throw CoreControllerError.unconfirmed }
            catch CoreControllerError.invalidRequest { }
        }
        // REJECT never opens an Internet connection, even for a delay test.
        guard try client.measureDelay(name: "REJECT") == .unavailable,
              try client.trafficTotals() == CoreTrafficTotals(uploadTotal: 0, downloadTotal: 0),
              try client.trafficSample() == CoreTrafficSample(up: 0, down: 0, upTotal: 0, downTotal: 0) else {
            throw CoreControllerError.unconfirmed
        }
        let result: [String: Any] = ["version": version, "peerIdentityRejected": true, "modesVerified": 3,
            "groupsSelectedAndReadBack": groups.count, "invalidMemberRejected": true,
            "rejectDelayUnavailable": true, "zeroTrafficTotals": true, "boundedTrafficSample": true]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) + Data([10]))
    }
}
#endif
