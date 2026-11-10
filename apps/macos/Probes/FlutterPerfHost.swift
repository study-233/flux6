// Injected only into the QA runner by probe-flutter-perf.sh.
import CoreVideo
import QuartzCore

private final class PerfTicks {
    private let lock = NSLock()
    private var last: CFTimeInterval?
    private var intervals: [Int] = []
    func tick() {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        if let last { intervals.append(Int(((now - last) * 1_000_000).rounded())) }
        last = now
    }
    func reset() { lock.lock(); last = nil; intervals.removeAll(keepingCapacity: true); lock.unlock() }
    func values() -> [Int] { lock.lock(); defer { lock.unlock() }; return intervals }
}

@MainActor final class PerfDisplay: NSObject {
    static let shared = PerfDisplay()
    private let software = PerfTicks(), hardware = PerfTicks()
    private var link: CADisplayLink?
    private var cv: CVDisplayLink?
    private var origin: NSPoint = .zero
    private(set) var dragCalls = 0
    private var pointerBeforeDrag: CGPoint?
    func noteDrag() { dragCalls += 1 }
    @objc private func displayTick(_ sender: CADisplayLink) { software.tick() }
    func handle(_ method: String, _ args: [String: Any], _ window: NSWindow) -> Any {
        switch method {
        case "perfInfo":
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if link == nil, let view = window.contentView, let screen = window.screen {
                link = view.displayLink(target: self, selector: #selector(displayTick(_:)))
                link?.add(to: .main, forMode: .common)
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
                guard CVDisplayLinkCreateWithCGDisplay(id, &cv) == kCVReturnSuccess, let cv else { return [:] }
                CVDisplayLinkSetOutputCallback(cv, { _, _, _, _, _, context in
                    guard let context else { return kCVReturnError }
                    Unmanaged<PerfTicks>.fromOpaque(context).takeUnretainedValue().tick()
                    return kCVReturnSuccess
                }, Unmanaged.passUnretained(hardware).toOpaque())
                guard CVDisplayLinkStart(cv) == kCVReturnSuccess else { return [:] }
            }
            origin = window.frame.origin
            return ["screen": window.screen?.localizedName ?? "", "scale": window.backingScaleFactor,
                    "maximumHz": window.screen?.maximumFramesPerSecond ?? 0,
                    "thermal": ProcessInfo.processInfo.thermalState.rawValue, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString, "visible": window.isVisible,
                    "screenWidth": window.screen?.frame.width ?? 0, "screenHeight": window.screen?.frame.height ?? 0]
        case "perfPause":
            link?.isPaused = true
            if let cv { CVDisplayLinkStop(cv) }
            return true
        case "perfResume":
            if let cv { CVDisplayLinkStart(cv) }
            link?.isPaused = false
            return true
        case "perfStart": software.reset(); hardware.reset(); return true
        case "perfEnd": return ["mainUs": software.values(), "cvUs": hardware.values(), "thermal": ProcessInfo.processInfo.thermalState.rawValue]
        case "perfManualStart":
            origin = window.frame.origin
            dragCalls = 0
            pointerBeforeDrag = CGEvent(source: nil)?.location
            return ["windowID": window.windowNumber, "originX": origin.x, "originY": origin.y,
                    "active": NSApp.isActive && window.isKeyWindow, "visible": window.isVisible]
        case "perfManualEnd":
            guard let point = pointerBeforeDrag else { return false }
            pointerBeforeDrag = nil
            return CGWarpMouseCursorPosition(point) == .success
        case "perfPointerStart":
            // Post events strictly to this application. They pass through the
            // Flutter title-strip Listener and the normal AppKit drag method.
            origin = window.frame.origin
            dragCalls = 0
            let size = window.contentView!.bounds.size
            let down = NSPoint(x: size.width * 0.60, y: size.height - 34)
            let global = window.convertPoint(toScreen: down)
            for i in 0...25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(i * 16 + 20)) {
                    let p = NSPoint(x: global.x + CGFloat(i) * 2, y: global.y + CGFloat(i))
                    let type: NSEvent.EventType = i == 0 ? .leftMouseDown : i == 25 ? .leftMouseUp : .leftMouseDragged
                    if let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: p),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: i + 1,
                        clickCount: 1, pressure: i == 25 ? 0 : 1) {
                        if args["delivery"] as? String == "targetPid", let cg = event.cgEvent {
                            cg.postToPid(ProcessInfo.processInfo.processIdentifier)
                        } else {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
            }
            return true
        case "perfPointerReport":
            return ["nativeDragCalls": dragCalls, "deltaX": window.frame.origin.x - origin.x,
                    "deltaY": window.frame.origin.y - origin.y]
        case "perfMove":
            let delta = args["delta"] as? CGFloat ?? 0
            window.setFrameOrigin(NSPoint(x: origin.x + delta, y: origin.y + delta / 3))
            return [window.frame.origin.x, window.frame.origin.y]
        default: return false
        }
    }
}
