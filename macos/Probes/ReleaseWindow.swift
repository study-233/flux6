import AppKit
import CoreGraphics
import Vision

// Only inspect the given test process/window. Never request screen or AX permission.
let args = CommandLine.arguments
guard args.count == 3 else { exit(64) }
if args[1] == "recognize" {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try VNImageRequestHandler(url: URL(fileURLWithPath: args[2])).perform([request])
    print((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
    exit(0)
}
guard args[1] == "inspect", let pid = Int32(args[2]),
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
      app.bundleIdentifier == "dev.freev6.desktop",
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { exit(2) }
let matching = windows.filter {
    $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0
}
guard let window = matching.first,
      let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { exit(3) }
let result: [String: Any] = ["window": window[kCGWindowNumber as String] ?? 0,
    "title": window[kCGWindowName as String] as? String ?? "",
    "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0,
    "finished": app.isFinishedLaunching, "bundle": app.bundleURL?.standardizedFileURL.path ?? "",
    "captureAvailable": CGPreflightScreenCaptureAccess()]
print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
