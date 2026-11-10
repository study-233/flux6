#if DEBUG
import Darwin
import Foundation

public enum CoreDownloadProbe {
    public static func run(path: String, pid: pid_t, port: Int, scenario: String) throws {
        guard geteuid() != 0, pid > 1, pid != getpid(), (1024...65535).contains(port),
              ["normal", "cancel", "oversized", "httpError", "partial", "badNode"].contains(scenario) else {
            throw CoreControllerError.invalidRequest
        }
        let directory = try SecureDirectory(path: path, owner: geteuid())
        let controller = try CoreController(probeDirectory: directory, currentPID: { pid })
        try controller.waitUntilReady()
        let token = UUID(), before = try controller.controls(token: token), cancellation = DownloadCancellation()
        if scenario == "cancel" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { cancellation.cancel() } }
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = Result {
            try controller.measureDownload(group: .access, member: scenario == "badNode" ? "missing" : "test-B", cancellation: cancellation,
                endpoint: "https://localhost:\(port)/" + scenario, caFile: path + "/cert.pem")
        }
        guard try controller.controls(token: token) == before,
              try controller.proxies()[CoreDownload.group]?.now == "REJECT" else { throw CoreControllerError.unconfirmed }
        var report: [String: Any] = ["scenario": scenario, "selectionUnchanged": true, "channelReset": true,
                                     "elapsed": ProcessInfo.processInfo.systemUptime - start]
        switch outcome {
        case .success(let value):
            guard scenario == "normal" || scenario == "partial" else { throw CoreControllerError.invalidResponse }
            report["bytes"] = value.bytes; report["bytesPerSecond"] = value.bytesPerSecond
        case .failure(let error):
            if scenario == "cancel" { guard error is CancellationError else { throw error } }
            else if !["oversized", "httpError", "badNode"].contains(scenario) { throw error }
            report["failedAsExpected"] = true
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: .sortedKeys) + Data([10]))
    }
}
#endif
