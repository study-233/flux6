import AppKit
import SwiftUI
import FreeV6Desktop

@main enum FreeV6Entry {
    @MainActor static func main() {
        // Choose before constructing AppModel. An image launch should only
        // show installation instructions, even if this account enabled auto-connect.
        if (try? ApplicationLocation.requiresInstallation(at: Bundle.main.bundleURL)) == false {
            FreeV6App.main()
        } else {
            InstallationApp.main()
        }
    }
}

private final class InstallationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct InstallationApp: App {
    @NSApplicationDelegateAdaptor(InstallationDelegate.self) private var delegate

    var body: some Scene {
        Window("安装 FreeV6", id: "install") {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "arrow.right.doc.on.clipboard").font(.largeTitle).foregroundStyle(.blue)
                Text("安装 FreeV6")
                    .font(.title2.bold()).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
                Text("在 Finder 中打开下载的 DMG，将 FreeV6 拖到旁边的 Applications 文件夹。").font(.headline)
                Text("退出此窗口，推出磁盘映像，然后从“应用程序”打开 FreeV6。")
                HStack {
                    Button("打开“应用程序”") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("退出") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                }.padding(.top, 12)
            }.padding(24).frame(width: 460)
        }.windowResizability(.contentSize)
    }
}
