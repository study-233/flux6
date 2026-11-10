import AppKit
import FlutterMacOS
import FreeV6Host
import ServiceManagement
import UniformTypeIdentifiers

/// Each engine owns its subscription and panels. All engines use the same native coordinator.
@MainActor
final class HostWindowChannel: NSObject, @preconcurrency FlutterStreamHandler {
    let role: String
    weak var window: NSWindow?
    private weak var app: HostApplication?
    private let method: FlutterMethodChannel
    private let events: FlutterEventChannel
    private var observation: UUID?
    private var handoffs: [String: URL] = [:]
    private(set) var isDirty = false

    init(window: NSWindow, role: String, controller: FlutterViewController, app: HostApplication) {
        self.window = window
        self.role = role
        self.app = app
        let messenger = controller.engine.binaryMessenger
        method = FlutterMethodChannel(name: "dev.freev6.host/v1", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "dev.freev6.host/v1/events", binaryMessenger: messenger)
        super.init()
        method.setMethodCallHandler { [weak self] call, reply in
            guard let self else { reply(FlutterError(code: "closed", message: "窗口已关闭", details: nil)); return }
            Task { @MainActor in await self.handle(call, reply: reply) }
        }
        events.setStreamHandler(self)
    }

    func close() {
        removeObservation()
        method.setMethodCallHandler(nil)
        events.setStreamHandler(nil)
        for folder in handoffs.values { try? FileManager.default.removeItem(at: folder) }
        handoffs.removeAll()
    }

    func onListen(withArguments arguments: Any?, eventSink sink: @escaping FlutterEventSink) -> FlutterError? {
        guard let app else { return FlutterError(code: "closed", message: "窗口已关闭", details: nil) }
        removeObservation()
        do {
            let coordinator = try app.coordinator.get()
            let id = coordinator.observe { [weak app] value in
                guard let app, let native = value["snapshot"] as? [String: Any] else { return }
                var event = value
                event["snapshot"] = app.displaying(native)
                sink(event)
            }
            observation = id
            // A fresh baseline also covers channel subscriptions that arrive after the initial snapshot.
            Task { @MainActor [weak self] in
                let state = await coordinator.snapshot()
                guard self?.observation == id else { return }
                sink(["version": 1, "cursor": state["cursor"] ?? 0, "kind": "state", "snapshot": app.displaying(state)] as [String: Any])
            }
            return nil
        } catch {
            return FlutterError(code: "host-unavailable", message: error.localizedDescription, details: nil)
        }
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        removeObservation()
        return nil
    }

    private func removeObservation() {
        if let observation, let coordinator = try? app?.coordinator.get() {
            coordinator.removeObserver(observation)
        }
        observation = nil
    }

    func uiAction(_ action: String, args: [String: Any] = [:]) {
        method.invokeMethod("uiAction", arguments: ["action": action, "args": args])
    }

    func resolveDrafts(saving: Bool) async -> Bool {
        let completed: Bool = await withCheckedContinuation { continuation in
            let response = DraftResponse(continuation)
            response.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                response.complete(false)
            }
            method.invokeMethod("uiAction", arguments: ["action": saving ? "saveDrafts" : "discardDrafts", "args": [:]]) {
                response.complete($0 as? Bool == true)
            }
        }
        if completed { isDirty = false }
        return completed
    }

    private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) async {
        guard let app, let window else { reply(FlutterError(code: "closed", message: "窗口已关闭", details: nil)); return }
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "windowRole":
                app.start()
                reply(role)
            #if !FREEV6_RELEASE_HOST
            case "qaWindowInfo":
                guard HostApplication.isQA else { reply(FlutterMethodNotImplemented); return }
                let size = window.contentView?.bounds.size ?? .zero
                reply(["role": role, "width": size.width, "height": size.height,
                       "visible": window.isVisible, "menu": NSApp.mainMenu?.items.map(\.title) ?? [],
                       "delegate": NSApp.delegate.map { NSStringFromClass(type(of: $0)) } ?? ""] as [String: Any])
            #endif
            case "snapshot":
                let state = await (try app.coordinator.get()).snapshot()
                reply(app.displaying(state))
            case "command":
                let inputs = args["arguments"] as? [String: Any] ?? [:]
                var consumed: URL?
                if args["name"] as? String == "profile.import", inputs["source"] as? String == "file" {
                    guard let path = inputs["value"] as? String, let folder = handoffs.removeValue(forKey: path) else {
                        throw HostActionError.fileNotSelected
                    }
                    consumed = folder
                }
                defer { if let consumed { try? FileManager.default.removeItem(at: consumed) } }
                var response = await (try app.coordinator.get()).command(args)
                if let native = response["snapshot"] as? [String: Any] { response["snapshot"] = app.displaying(native) }
                reply(response)
            case "openSettings": app.showSettings(); reply(true)
            case "openMain": app.showMain(); reply(true)
            case "quit":
                reply(true)
                app.requestQuit()
            case "setDirty":
                guard let dirty = args["dirty"] as? Bool else { throw CocoaError(.coderInvalidValue) }
                isDirty = dirty
                window.isDocumentEdited = dirty
                reply(true)
            case "setSize":
                guard let width = args["width"] as? CGFloat, let height = args["height"] as? CGFloat,
                      width.isFinite, height.isFinite, width > 0, height > 0 else { throw CocoaError(.coderInvalidValue) }
                MainFlutterWindow.resize(window, width: width, height: height)
                reply(true)
            case "startDragging":
                MainFlutterWindow.drag(window)
                reply(nil)
            case "pickFile", "openFile", "chooseFile": reply(try await pickFile(args: args, asPath: call.method != "openFile" || args["kind"] as? String == "path"))
            case "exportText", "saveFile", "exportFile": reply(try await exportFile(args))
            case "openURL":
                guard let address = args["url"] as? String, let parts = URLComponents(string: address),
                      parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
                      parts.user == nil, parts.password == nil, let url = parts.url else { throw CocoaError(.fileReadUnsupportedScheme) }
                reply(NSWorkspace.shared.open(url))
            case "openLoginSettings":
                guard HostApplication.isOfficial else { throw HostActionError.isolated }
                SMAppService.openSystemSettingsLoginItems()
                reply(true)
            case "checkUpdates":
                guard HostApplication.isOfficial else { throw HostActionError.isolated }
                try app.checkUpdates()
                reply(true)
            default: reply(FlutterMethodNotImplemented)
            }
        } catch {
            reply(FlutterError(code: (error as? HostActionError)?.code ?? "host-failure", message: error.localizedDescription, details: nil))
        }
    }

    private func pickFile(args: [String: Any], asPath: Bool) async throws -> String? {
        guard let window, window.attachedSheet == nil else { throw HostActionError.panelInUse }
        let panel = NSOpenPanel()
        panel.title = args["title"] as? String ?? "选取配置文件"
        panel.allowedContentTypes = ["yaml", "yml", "json", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maxBytes = 2 * 1024 * 1024
        let bytes = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard bytes.count <= maxBytes else { throw HostActionError.fileTooLarge }
        guard asPath else {
            guard let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return text
        }
        // Keep a bounded private handoff readable by the sandboxed worker after the panel scope ends.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freev6-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let handoff = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try bytes.write(to: handoff, options: .withoutOverwriting)
            // A second selection supersedes any previous unused selection in the same window.
            for previous in handoffs.values { try? FileManager.default.removeItem(at: previous) }
            handoffs = [handoff.path: folder]
            return handoff.path
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func exportFile(_ args: [String: Any]) async throws -> Bool {
        guard let window, window.attachedSheet == nil else { throw HostActionError.panelInUse }
        guard let text = args["text"] as? String else { throw CocoaError(.coderInvalidValue) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (args["name"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Flux6-日志.txt"
        panel.title = args["title"] as? String ?? "导出 Flux6 记录"
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }
}

@MainActor private final class DraftResponse {
    private var reply: CheckedContinuation<Bool, Never>?
    var timeout: Task<Void, Never>?
    init(_ reply: CheckedContinuation<Bool, Never>) { self.reply = reply }
    func complete(_ value: Bool) {
        guard let reply else { return }
        self.reply = nil
        timeout?.cancel()
        timeout = nil
        reply.resume(returning: value)
    }
}

enum HostActionError: LocalizedError {
    case isolated, panelInUse, fileTooLarge, fileNotSelected
    var code: String {
        switch self {
        case .isolated: "unsupported"
        case .panelInUse: "panel-busy"
        case .fileTooLarge: "file-size"
        case .fileNotSelected: "file-selection"
        }
    }
    var errorDescription: String? {
        switch self {
        case .isolated: "本地验收版使用独立身份，此操作仅适用于正式客户端。"
        case .panelInUse: "请先关闭当前窗口的对话框。"
        case .fileTooLarge: "配置文件超过 2 MiB，请选择较小的文件。"
        case .fileNotSelected: "请重新从这个窗口选取要导入的配置文件。"
        }
    }
}
