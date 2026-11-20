import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let controller = FlutterViewController()
        let initialFrame = frame
        contentViewController = controller
        setFrame(initialFrame, display: true)
        title = "Flux6 Preview"
        RegisterGeneratedPlugins(registry: controller)
        super.awakeFromNib()
    }
}
