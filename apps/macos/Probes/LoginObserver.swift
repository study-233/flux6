// No windows or network. Launch Services opens this temporary app so the login
// probe can observe its actual launch arguments and process identity.
import AppKit

@MainActor final class Observer: NSObject, NSApplicationDelegate {
    func record(_ event: String) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ProbeEvents") as? String,
              let file = fopen(path, "a"),
              let data = try? JSONSerialization.data(withJSONObject: [
                "event": event, "pid": getpid(), "arguments": CommandLine.arguments.dropFirst().map { $0 }
              ]) else { exit(2) }
        data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, file) }
        fputc(10, file)
        fclose(file)
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        record("launched")
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { NSApp.terminate(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        record("reopened"); return false
    }
    func applicationWillTerminate(_ notification: Notification) { record("terminated") }
}

@main struct LoginObserverMain {
    static func main() {
        let app = NSApplication.shared
        let observer = Observer()
        app.delegate = observer
        app.run()
    }
}
