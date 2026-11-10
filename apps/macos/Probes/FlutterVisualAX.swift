import AppKit
import FlutterMacOS

// Linked only into the isolated audit build. Read the accessibility elements
// supplied by the Flutter engine through AppKit, as a Mac accessibility client would.
@MainActor
enum FlutterVisualAX {
    // The Flutter 3.47 embedder normally enables this engine's AX bridge when
    // an accessibility client attaches. Exercise that same bridge in the QA
    // process without changing the user's macOS VoiceOver preference.
    static func enable(in window: NSWindow) -> Bool {
        guard let engine = (window.contentViewController as? FlutterViewController)?.engine,
              engine.responds(to: NSSelectorFromString("setSemanticsEnabled:")) else { return false }
        engine.setValue(true, forKey: "semanticsEnabled")
        return true
    }
    static func sendKey(_ name: String, to window: NSWindow) {
        let keys: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "escape": (53, "\u{1b}", []), "return": (36, "\r", []), "tab": (48, "\t", []),
            "nodes": (19, "2", .command), "find": (3, "f", .command)
        ]
        guard let (code, text, flags) = keys[name] else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown, !flags.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
            window.sendEvent(event)
        }
    }
    static func snapshot(window: NSWindow) -> [String: Any] {
        var rows: [[String: Any]] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ item: Any, depth: Int) {
            guard depth < 32, rows.count < 800, let node = item as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            let label = node.accessibilityLabel() ?? ""
            let value = node.accessibilityValue()
            let text = value as? String ?? (value as? NSNumber)?.stringValue ?? ""
            rows.append(["role": node.accessibilityRole()?.rawValue ?? "", "label": label,
                         "value": text, "enabled": node.isAccessibilityEnabled(),
                         "selected": node.isAccessibilitySelected(), "help": node.accessibilityHelp() ?? ""])
            for child in node.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        if let view = window.contentView { visit(view, depth: 0) }
        return ["voiceOverEnabled": NSWorkspace.shared.isVoiceOverEnabled, "nodes": rows]
    }
}
