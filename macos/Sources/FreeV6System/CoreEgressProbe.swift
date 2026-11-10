#if DEBUG
import Darwin
import Foundation

/// Exercises the production startup gate with a pinned ordinary-user core and
/// a synthetic localhost TLS server. No arbitrary URL or CA enters Release.
public enum CoreEgressProbe {
    public static func run(path: String, pid: pid_t, proxyPort: Int, targetPort: Int) throws {
        guard geteuid() != 0, pid > 1, pid != getpid(),
              (1024...65535).contains(proxyPort), (1024...65535).contains(targetPort) else {
            throw CoreControllerError.invalidRequest
        }
        let directory = try SecureDirectory(path: path, owner: geteuid())
        let client = try CoreController(probeDirectory: directory, currentPID: { pid })
        _ = try client.waitUntilReady()
        var codes = [Int32](), routed = false
        let began = ProcessInfo.processInfo.systemUptime
        try CoreEgressCheck.waitUntilUsable(timeout: 10, validateIdentity: { _ = try client.version() }, request: { timeout in
            let result = try CapturedCommand.run(executable: "/usr/bin/curl", arguments: [
                "--disable", "--silent", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                "--proto", "=https", "--cacert", path + "/cert.pem", "--connect-timeout", "2",
                "--max-time", String(max(0.001, timeout)), "--max-filesize", "1024", "--output", "/dev/null",
                "--write-out", "%{http_code} %{remote_ip}", "https://localhost:\(targetPort)/generate_204"
            ], timeout: timeout + 2, limit: 256)
            if case .exited(let code) = result.exit {
                codes.append(code)
                FileHandle.standardOutput.write(Data("{\"attemptExit\":\(code)}\n".utf8))
            }
            return result
        }, validatePeer: { ip, ipv4 in
            guard ipv4, ip == "127.0.0.1" else { throw NetworkRunError.egressUnavailable }
            routed = true
        })
        let result: [String: Any] = ["exits": codes, "peerVerified": routed,
            "elapsed": ProcessInfo.processInfo.systemUptime - began]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) + Data([10]))
    }
}
#endif
