#if DEBUG
import Darwin
import Foundation

/// Ordinary-user test host only. Release has no preparation/recovery probe
/// entry points, and the service XPC protocol does not expose these operations.
public enum SessionPreparationProbe {
    public static func failedCheck(path: String, request: Data, failure: String) throws {
        guard geteuid() != 0, ["rejected", "timeout"].contains(failure) else { throw ServiceMessageError.invalid }
        let store = try PreparedSessionStore(path: path, owner: geteuid())
        let resources = try ServiceResourceStore(path: path + "/resources", owner: geteuid())
        let record = try resources.prepareSession(request, clientUID: geteuid(), sessions: store)
        store.checkCheckpoint = { name in
            do {
                if failure == "rejected", name == "registered" {
                    // Fault injection after immutable-copy verification. This
                    // arbitrary mutation exists only in a non-root Debug host.
                    let folder = try SecureDirectory(path: path + "/sessions/" + record.sessionID.uuidString, owner: geteuid())
                    try folder.write("config.json", data: Data("invalid: [".utf8), mode: 0o600)
                }
                if failure == "timeout", name == "job-started" {
                    let job = "gui/\(geteuid())/dev.freev6.core." + record.sessionID.uuidString.lowercased()
                    let command = try OwnedChildProcess(executable: "/bin/launchctl", arguments: ["kill", "SIGSTOP", job], directory: "/")
                    guard try command.runToExit(timeout: 5) == .exited(0) else { exit(3) }
                }
            } catch { exit(3) }
        }
        do {
            try store.checkConfiguration(sessionID: record.sessionID, clientUID: geteuid())
            throw ServiceMessageError.invalid
        } catch ConfigurationCheckError.coreRejected where failure == "rejected" {}
        catch CoreJobError.timedOut where failure == "timeout" {}
        guard try store.current() == nil, try FileManager.default.contentsOfDirectory(atPath: path + "/sessions").isEmpty,
              try ManagedCoreJob(probeSessionID: record.sessionID).status() == nil else { throw ServiceMessageError.invalid }
    }

    public static func holdCheck(path: String, request: Data, checkpoint: String) throws {
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        let store = try PreparedSessionStore(path: path, owner: geteuid())
        let resources = try ServiceResourceStore(path: path + "/resources", owner: geteuid())
        store.checkCheckpoint = { name in
            guard name == checkpoint else { return }
            // The journal is bounded, private and never contains credentials.
            guard let journal = try? Data(contentsOf: URL(fileURLWithPath: path + "/" + PreparedSessionStore.journalName)) else { exit(2) }
            FileHandle.standardOutput.write(journal + Data([10]))
            DispatchSemaphore(value: 0).wait()
        }
        let record = try resources.prepareSession(request, clientUID: geteuid(), sessions: store)
        try store.checkConfiguration(sessionID: record.sessionID, clientUID: geteuid())
        throw ServiceMessageError.invalid // The selected crash boundary must run.
    }

    public static func recoverCheck(path: String) throws {
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        try PreparedSessionStore(path: path, owner: geteuid()).recoverConfigurationCheck()
    }

    public static func holdGroup(executable: String, directory: String) throws {
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        let origin = try ServiceProcessOrigin.current()
        let child = try OwnedChildProcess(executable: executable, arguments: ["ignore-term", directory + "/child-ready"],
            directory: directory, group: .inheritService)
        let data = try JSONSerialization.data(withJSONObject: ["hostPID": getpid(), "childPID": child.pid, "groupID": origin.groupID])
        FileHandle.standardOutput.write(data + Data([10]))
        withExtendedLifetime(child) { DispatchSemaphore(value: 0).wait() }
    }

    public static func hold(path: String, request: Data, partial: Bool) throws {
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        let store = try PreparedSessionStore(path: path, owner: geteuid())
        let record: PreparedSessionRecord
        if partial {
            enum Interruption: Error { case simulated }
            do {
                _ = try store.prepare(ServiceMessages.decodeConfiguration(request), clientUID: geteuid()) { directory in
                    try directory.write("country.mmdb", data: Data("partial preparation fixture".utf8), mode: 0o400)
                    throw Interruption.simulated
                }
                throw ServiceMessageError.invalid
            } catch Interruption.simulated {}
            guard let pending = try store.current() else { throw ServiceMessageError.invalid }
            record = pending
        } else {
            let resources = try ServiceResourceStore(path: path + "/resources", owner: geteuid())
            record = try resources.prepareSession(request, clientUID: geteuid(), sessions: store)
            try store.withVerifiedWorkspace(sessionID: record.sessionID, clientUID: geteuid()) { _ in () }
        }
        let summary = try JSONSerialization.data(withJSONObject: ["sessionID": record.sessionID.uuidString, "phase": record.phase.rawValue])
        FileHandle.standardOutput.write(summary + Data([10]))
        // Parent sends SIGKILL to simulate a daemon crash. Never launch a core
        // while using this preparation-only journal schema.
        withExtendedLifetime(store) { _ = FileHandle.standardInput.readData(ofLength: 1) }
    }

    public static func recover(path: String) throws {
        guard geteuid() != 0 else { throw ServiceMessageError.invalid }
        let store = try PreparedSessionStore(path: path, owner: geteuid())
        try store.recoverPreparation()
    }
}
#endif
