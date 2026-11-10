import AppKit
import SwiftUI
import FreeV6Business

/// The native editor can select and reveal the exact rejected line on macOS 14 as well.
struct RuleTextEditor: NSViewRepresentable {
    @Binding var text: String
    let field: ProxyRuleField
    let issue: ProxyRuleIssue?
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var lastIssue: UUID?

        init(_ text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)): textView.window?.selectNextKeyView(nil)
            case #selector(NSResponder.insertBacktab(_:)): textView.window?.selectPreviousKeyView(nil)
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.setAccessibilityLabel(field.title)
        editor.delegate = context.coordinator
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        editor.isEditable = isEnabled
        if editor.string != text { editor.string = text }
        editor.setAccessibilityHelp(issue?.message)
        guard let issue, issue.id != context.coordinator.lastIssue else { return }
        context.coordinator.lastIssue = issue.id
        let rejectedText = text
        // Opening a disclosure creates its editor before it is attached to the key window.
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window, window.isKeyWindow,
                  rejectedText == editor.string, NSMaxRange(issue.range) <= (editor.string as NSString).length else { return }
            window.makeFirstResponder(editor)
            editor.setSelectedRange(issue.range)
            editor.scrollRangeToVisible(issue.range)
            NSAccessibility.post(element: editor, notification: .announcementRequested,
                userInfo: [.announcement: issue.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
