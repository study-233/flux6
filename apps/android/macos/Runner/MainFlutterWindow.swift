import Cocoa
import Security
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    private var hiddenAtLaunch = false

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        RegisterGeneratedPlugins(registry: flutterViewController)
        FlutterMethodChannel(name: "dev.freev6.mobile/storage", binaryMessenger: flutterViewController.engine.binaryMessenger)
            .setMethodCallHandler { call, reply in
                DispatchQueue.global(qos: .userInitiated).async {
                    let value = Self.handleCredential(call)
                    DispatchQueue.main.async { reply(value) }
                }
            }
        super.awakeFromNib()
    }
    private static func handleCredential(_ call: FlutterMethodCall) -> Any? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.freev6.desktop.warp",
            kSecAttrAccount as String: "credentials-v2"
        ]
        let error = FlutterError(code: "credential_store", message: "Keychain access failed", details: nil)
        switch call.method {
        case "read":
            var query = base
            query[kSecReturnData as String] = true
            var stored: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &stored)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = stored as? Data,
                  let text = String(data: data, encoding: .utf8) else { return error }
            return text
        case "write":
            guard let text = call.arguments as? String, text.utf8.count <= 32768 else { return error }
            let changes = [kSecValueData as String: Data(text.utf8)]
            var status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(base.merging(changes) { _, value in value } as CFDictionary, nil)
            }
            if status != errSecSuccess { return error }
            return nil
        case "clearLegacy":
            let files = FileManager.default
            guard let library = files.urls(for: .libraryDirectory, in: .userDomainMask).first else { return error }
            for folder in ["Logs", "Caches"] {
                let old = library.appendingPathComponent(folder).appendingPathComponent("dev.freev6.desktop")
                do { try files.removeItem(at: old) }
                catch let failure as NSError where failure.domain == NSCocoaErrorDomain && failure.code == NSFileNoSuchFileError { continue }
                catch { return FlutterError(code: "legacy_storage", message: "Could not clear old Flux6 files", details: nil) }
            }
            if let id = Bundle.main.bundleIdentifier, id == "dev.freev6.desktop" {
                UserDefaults.standard.removePersistentDomain(forName: id)
            }
            let login = library.appendingPathComponent("LaunchAgents/dev.freev6.desktop.login.plist")
            if files.fileExists(atPath: login.path) {
                do { try files.removeItem(at: login) }
                catch { return FlutterError(code: "legacy_storage", message: "Could not clear old login item", details: nil) }
            }
            for (service, account) in [("warp", "credentials-v1"), ("cloud", "snapshot-key-v1"), ("chain", "snapshot-key-v1")] {
                var query = base
                query[kSecAttrService as String] = "dev.freev6.desktop." + service
                query[kSecAttrAccount as String] = account
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound { return error }
            }
            return nil
        default:
            return FlutterMethodNotImplemented
        }
    }
    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        // Only the first order hides the window, which Dart shows once it is configured.
        if !hiddenAtLaunch {
            hiddenAtLaunch = true
            setIsVisible(false)
        }
    }
}
