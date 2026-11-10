import AppKit
import QuartzCore
import SwiftUI
import FreeV6Desktop

/// Feedback belongs to the hit target; it should never animate the surrounding layout.
struct ControlPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.08 : 0.13),
                       value: configuration.isPressed)
    }
}

struct ToolbarPageSelector: View {
    @ObservedObject var navigation: WindowNavigation
    var body: some View {
        PageStrip(page: navigation.page, onSelect: navigation.show)
            .frame(width: PageRail.size.width, height: PageRail.size.height)
    }
}

/// The toolbar keeps one AppKit view across page changes. Only the selection
/// layer moves; a second click can interrupt it at its current screen position.
struct PageStrip: NSViewRepresentable {
    let page: Page
    let onSelect: (Page) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> PageRail { PageRail() }
    func updateNSView(_ view: PageRail, context: Context) {
        view.select = onSelect
        view.update(page, motion: !reduceMotion)
    }
}

private final class PageKey: NSButton {
    var step: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 { step?(event.keyCode == 123 ? -1 : 1) }
        else { super.keyDown(with: event) }
    }
}

final class PageRail: NSView {
    static let size = CGSize(width: 242, height: 30)
    var select: ((Page) -> Void)?
    private let indicator = CALayer()
    private var buttons: [NSButton] = []
    private var current: Page?
    private var motionEnabled = true
    override var intrinsicContentSize: NSSize { Self.size }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        indicator.cornerRadius = 8
        indicator.cornerCurve = .continuous
        layer?.addSublayer(indicator)
        setAccessibilityElement(false)
        for (index, page) in Page.allCases.enumerated() {
            let key = PageKey(title: page.title, target: self, action: #selector(choose(_:)))
            key.tag = index
            key.isBordered = false
            key.bezelStyle = .regularSquare
            key.setButtonType(.momentaryChange)
            key.focusRingType = .exterior
            key.setAccessibilityRole(.radioButton)
            key.setAccessibilityLabel(page.title)
            key.toolTip = page.title + "（⌘" + String(index + 1) + "）"
            key.step = { [weak self, weak key] delta in
                guard let self, let key else { return }
                let next = min(max(0, key.tag + delta), buttons.count - 1)
                window?.makeFirstResponder(buttons[next])
                activate(Page.allCases[next])
            }
            buttons.append(key)
            addSubview(key)
        }
        retint()
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retint()
        if let current { updateButtons(current) }
    }
    private func retint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.065).cgColor
            indicator.backgroundColor = NSColor.controlBackgroundColor.cgColor
            indicator.borderColor = NSColor.labelColor.withAlphaComponent(0.13).cgColor
            indicator.borderWidth = 0.7
            CATransaction.commit()
        }
    }
    private func slot(_ index: Int) -> CGRect {
        let size = bounds.isEmpty ? Self.size : bounds.size
        let width = (size.width - 4) / CGFloat(Page.allCases.count)
        return CGRect(x: 2 + width * CGFloat(index), y: 2, width: width, height: size.height - 4)
    }
    override func layout() {
        super.layout()
        for (i, button) in buttons.enumerated() { button.frame = slot(i) }
        if let current, let i = Page.allCases.firstIndex(of: current) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            indicator.frame = slot(i)
            CATransaction.commit()
        }
    }
    func update(_ page: Page, motion: Bool) {
        guard let index = Page.allCases.firstIndex(of: page) else { return }
        motionEnabled = motion
        if !motion { indicator.removeAnimation(forKey: "selection") }
        guard page != current else { return }
        let start = (indicator.presentation() ?? indicator).position
        let animate = motion && current != nil && window != nil
        let previous = current
        current = page
        CATransaction.begin(); CATransaction.setDisableActions(true)
        indicator.frame = slot(index)
        CATransaction.commit()
        if animate {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: start)
            slide.toValue = NSValue(point: indicator.position)
            slide.duration = 0.18
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            indicator.add(slide, forKey: "selection")
        }
        updateButtons(page, replacing: previous)
    }
    private func updateButtons(_ page: Page, replacing previous: Page? = nil) {
        for (index, button) in buttons.enumerated() {
            let active = Page.allCases[index] == page
            if let previous, !active, Page.allCases[index] != previous { continue }
            button.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
            button.contentTintColor = active ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(active ? 1 : 0)
        }
    }
    @objc private func choose(_ sender: NSButton) {
        activate(Page.allCases[sender.tag])
    }
    private func activate(_ page: Page) {
        guard current != page else { return }
        update(page, motion: motionEnabled)
        // Commit the slide before SwiftUI mounts the destination for the first time.
        if motionEnabled { CATransaction.flush() }
        select?(page)
    }
}
