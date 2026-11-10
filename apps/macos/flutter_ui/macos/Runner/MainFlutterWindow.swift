import AppKit
import FlutterMacOS

final class MainFlutterWindow: NSWindow {
    private var previewChannel: FlutterMethodChannel?

    override func awakeFromNib() {
        if HostApplication.needsInstallation {
            let message = NSTextField(wrappingLabelWithString: "将 Flux6 拖到“应用程序”，推出磁盘映像，然后从“应用程序”打开。")
            let open = NSButton(title: "打开“应用程序”", target: self, action: #selector(openApplications))
            let quit = NSButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
            quit.keyEquivalent = "\r"
            let actions = NSStackView(views: [open, quit])
            let panel = NSStackView(views: [message, actions])
            panel.orientation = .vertical
            panel.alignment = .leading
            panel.spacing = 18
            panel.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
            title = "安装 Flux6"
            contentView = panel
            styleMask.remove(.resizable)
            setContentSize(NSSize(width: 450, height: 150))
            center()
            super.awakeFromNib()
            return
        }
        let controller = FlutterViewController()
        contentViewController = controller
        RegisterGeneratedPlugins(registry: controller)

        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isMovable = true
        title = "Flux6 Flutter Preview"
        contentMinSize = NSSize(width: 720, height: 480)

        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let width = min(1232, visible.width)
        let height = min(780, visible.height)
        setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
            display: false
        )
        if HostApplication.enabled {
            HostApplication.shared.attachMain(self, controller: controller)
            super.awakeFromNib()
            return
        }
        let channel = FlutterMethodChannel(
            name: "dev.freev6.flutter-preview/window",
            binaryMessenger: controller.engine.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let window = self else { result(nil); return }
            switch call.method {
            case "setSize":
                guard let values = call.arguments as? [String: NSNumber],
                      let width = values["width"]?.doubleValue,
                      let height = values["height"]?.doubleValue,
                      width.isFinite, height.isFinite, width > 0, height > 0 else {
                    result(FlutterError(code: "invalid-size", message: "Expected a positive window size.", details: nil))
                    return
                }
                Self.resize(window, width: width, height: height)
                result(nil)
            case "startDragging":
                Self.drag(window)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        previewChannel = channel
        super.awakeFromNib()
    }

    @objc private func openApplications() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }

    static func drag(_ window: NSWindow) {
        if let event = NSApp.currentEvent, event.window === window,
           event.type == .leftMouseDown || event.type == .leftMouseDragged {
            window.performDrag(with: event)
        }
    }

    static func resize(_ window: NSWindow, width: CGFloat, height: CGFloat) {
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let requested = NSRect(
            origin: .zero,
            size: NSSize(width: max(window.contentMinSize.width, width), height: max(window.contentMinSize.height, height))
        )
        let desired = window.frameRect(forContentRect: requested)
        let size = NSSize(width: min(visible.width, desired.width), height: min(visible.height, desired.height))
        let x = min(max(window.frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(window.frame.maxY - size.height, visible.minY), visible.maxY - size.height)
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}
