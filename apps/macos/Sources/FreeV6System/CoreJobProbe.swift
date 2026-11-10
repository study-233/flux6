#if DEBUG
import Darwin
import Foundation

/// Ordinary-user integration probe. Production has neither this entry point
/// nor a caller-selectable job domain or working directory over XPC.
public enum CoreJobProbe {
    public static func run(action: String, sessionID: UUID, path: String) throws {
        guard geteuid() != 0 else { throw CoreJobError.wrongContext }
        let directory = try SecureDirectory(path: path, owner: geteuid())
        try directory.requirePrivate()
        let job = try ManagedCoreJob(probeSessionID: sessionID)
        var result: [String: Any] = ["label": job.label]
        switch action {
        case "register": try job.register(directory: directory, checkOnly: true)
        case "start", "start-hold": result["startedPID"] = try job.start()
        case "wait": result["exit"] = try job.waitForExit(timeout: 20)
        case "stop": result["exit"] = try job.stop(gracePeriod: 0.2)
        case "remove": try job.removeStoppedJob()
        case "status": break
        default: throw CoreJobError.invalidState
        }
        if let state = try job.status() {
            result["loaded"] = true
            result["pid"] = state.pid
            result["lastExit"] = state.lastExit
        } else { result["loaded"] = false }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result) + Data([10]))
        if action == "start-hold" { DispatchSemaphore(value: 0).wait() }
    }
}
#endif
