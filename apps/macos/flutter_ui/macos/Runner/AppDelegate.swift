import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    if HostApplication.enabled { HostApplication.shared.start() }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !HostApplication.enabled
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    HostApplication.enabled ? HostApplication.shared.terminate(sender) : .terminateNow
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if HostApplication.enabled { HostApplication.shared.showMain(); return false }
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if HostApplication.enabled { HostApplication.shared.stopObserving() }
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
