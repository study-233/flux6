import AppKit
import Darwin

// Inspect and close only the freshly launched disposable Sparkle target.
// Never look up, activate, or terminate the user's ordinary Flux6 app.
let args = CommandLine.arguments
let prefix = "dev.freev6.flutter-host.qa."
guard args.count == 5, args[1].hasPrefix(prefix),
      UUID(uuidString: String(args[1].dropFirst(prefix.count))) != nil,
      let sourcePID = Int32(args[3]), ["inspect", "finish"].contains(args[4]) else { exit(64) }
let expected = URL(fileURLWithPath: args[2]).standardizedFileURL.path
guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first(where: {
    $0.processIdentifier != sourcePID && $0.bundleURL?.standardizedFileURL.path == expected && !$0.isTerminated
}) else { exit(2) }
if args[4] == "finish" {
    guard target.terminate() else { exit(3) }
    let deadline = Date(timeIntervalSinceNow: 8)
    while Date() < deadline, !target.isTerminated {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    exit(target.isTerminated ? 0 : 5)
}
guard target.isFinishedLaunching else { exit(4) }
print(target.processIdentifier)
