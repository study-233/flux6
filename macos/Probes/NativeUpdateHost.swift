// Isolated application host for the production Swift updater. The only automatic
// installation decision lives in this fixture; the product asks the user.
import AppKit

@MainActor final class HostDelegate: NSObject, NSApplicationDelegate {
    private var agent: Process?
    private let input = Pipe()
    private var allowed = false
    private var exitingAfterFailure = false

    private func record(_ name: String, _ details: [String: Any] = [:]) {
        var event = details
        event["event"] = name
        event["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        event["pid"] = getpid()
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ProbeResultPath") as? String,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let file = fopen(path, "a") else { exit(7) }
        data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, file) }
        fputc(10, file)
        fclose(file)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("launched")
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" { exit(0) }
        let child = Process()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FreeV6UpdateAgent.app/Contents/MacOS/freev6-update-agent")
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.standardError
        do { try child.run() } catch { record("launch-failed"); exit(2) }
        agent = child
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        DispatchQueue.global().async {
            do {
                while let event = try UpdatePipe.read(UpdateEvent.self, from: output.fileHandleForReading) {
                    Task { @MainActor in self.receive(event) }
                }
            } catch { Task { @MainActor in self.record("transport-failure"); exit(4) } }
        }
    }

    private func receive(_ event: UpdateEvent) {
        record(event.kind.rawValue, ["reason": event.failure?.rawValue ?? ""])
        if event.kind == .downloading, Bundle.main.object(forInfoDictionaryKey: "ProbeDecision") as? String == "cancel-download" {
            try? UpdatePipe.write(UpdateReply(operation: event.operation, install: false), to: input.fileHandleForWriting)
            record("download-cancelled")
        }
        if event.kind == .ready {
            let mode = Bundle.main.object(forInfoDictionaryKey: "ProbeDecision") as? String
            if mode == "crash" { exit(19) }
            if mode == "await-service" {
                // Only the fixture uses this pipe. Its parent replies after
                // verifying the registered service and the isolated DNS store.
                allowed = (try? FileHandle.standardInput.read(upToCount: 1)) == Data([1])
            } else {
                allowed = mode != "cancel"
            }
            record(allowed ? "network-confirmed" : "installation-cancelled")
            try? UpdatePipe.write(UpdateReply(operation: event.operation, install: allowed), to: input.fileHandleForWriting)
        }
        if event.kind == .failed || event.kind == .finished {
            exitingAfterFailure = true
            NSApp.terminate(nil)
        }
        if event.kind == .installing && allowed { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowed || exitingAfterFailure { record("terminating"); return .terminateNow }
        record("premature-termination-blocked")
        return .terminateCancel
    }
}

@main struct ProbeMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = HostDelegate()
        app.delegate = delegate
        app.run()
    }
}
