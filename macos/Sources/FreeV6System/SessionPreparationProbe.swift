#if DEBUG
import Darwin
import Foundation

/// Ordinary-user test host only. Release has no preparation/recovery probe
/// entry points, and the service XPC protocol does not expose these operations.
public enum SessionPreparationProbe {
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
