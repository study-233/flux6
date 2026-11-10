import AppKit

@main struct LoginLauncher {
    @MainActor static func main() async throws {
        guard geteuid() != 0, CommandLine.arguments.count == 1 else { throw CocoaError(.executableNotLoadable) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let root = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let app = Bundle(url: root), let id = app.bundleIdentifier, root.pathExtension == "app",
              executable.path == root.appendingPathComponent("Contents/Helpers/freev6-login-launcher").path,
              app.executableURL?.lastPathComponent == "FreeV6" else { throw CocoaError(.executableNotLoadable) }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--freev6-login"]
        config.activates = false
        config.createsNewApplicationInstance = false
        _ = try await NSWorkspace.shared.openApplication(at: root, configuration: config)
    }
}
