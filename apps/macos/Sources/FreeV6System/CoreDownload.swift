import Darwin
import Foundation

public struct CoreDownloadResult: Codable, Equatable, Sendable {
    public let bytes: Int
    public let seconds: Double
    public let measuredAt: Date
    public var bytesPerSecond: Double { Double(bytes) / seconds }
    public init(bytes: Int, seconds: Double, measuredAt: Date = Date()) {
        self.bytes = bytes; self.seconds = seconds; self.measuredAt = measuredAt
    }
    func validate() throws {
        guard (1...CoreDownload.maximumBytes).contains(bytes), seconds.isFinite, seconds > 0, seconds <= 15,
              measuredAt.timeIntervalSince1970.isFinite else { throw ServiceClientError.invalidReply }
    }
}

final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
}

enum CoreDownload {
    static let group = "__FreeV6_Download_Test__"
    static let listener = "__FreeV6_Download_In__"
    static let maximumBytes = 32 * 1024 * 1024
    static let endpoint = "https://speed.cloudflare.com/__down?bytes=33554432"

    // A separate authenticated inbound and selector isolate the test from the
    // active user selection, even when the user's mode is direct or global.
    static func addChannel(to document: inout [String: Any], password: String) throws {
        guard let nodes = document["proxies"] as? [[String: Any]],
              var groups = document["proxy-groups"] as? [[String: Any]] else { throw ServiceMessageError.invalid }
        let names = nodes.compactMap { $0["name"] as? String }
        guard !names.contains(group), !groups.contains(where: { $0["name"] as? String == group }) else {
            throw ServiceMessageError.invalid
        }
        groups.append(["name": group, "type": "select", "hidden": true, "proxies": ["REJECT"] + names])
        document["proxy-groups"] = groups
        document["listeners"] = [["name": listener, "type": "http", "listen": "127.0.0.1", "port": try availablePort(),
                                  "proxy": group, "users": [["username": "freev6-test", "password": password]]]]
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreControllerError.io }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout.size(ofValue: address))
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard ok else { throw CoreControllerError.io }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func run(directory: SecureDirectory, cancellation: DownloadCancellation,
                    endpoint: String = endpoint, caFile: String? = nil, verifyListener: (Int) throws -> Void) throws -> CoreDownloadResult {
        guard let data = try directory.read("config.json", limit: ServiceMessages.maximumConfigurationBytes),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listeners = config["listeners"] as? [[String: Any]],
              let channel = listeners.first(where: { $0["name"] as? String == listener }),
              channel["listen"] as? String == "127.0.0.1", channel["proxy"] as? String == group,
              let port = channel["port"] as? Int, (1024...65535).contains(port),
              let users = channel["users"] as? [[String: String]], let user = users.first,
              user["username"] == "freev6-test", let password = user["password"], password.count == 64,
              password.allSatisfy({ $0.isHexDigit }) else { throw CoreControllerError.invalidRequest }
        #if !DEBUG
        guard endpoint == Self.endpoint, caFile == nil else { throw CoreControllerError.invalidRequest }
        #endif
        try verifyListener(port)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--disable", "--config", "-", "--silent", "--show-error", "--fail", "--noproxy", "",
            "--proto", "=https", "--connect-timeout", "5", "--max-time", "10", "--max-filesize", String(maximumBytes),
            "--output", "/dev/null", "--write-out", "%{http_code} %{size_download} %{time_total} %{time_starttransfer}", endpoint]
        if let caFile { process.arguments! += ["--cacert", caFile] }
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try cancellation.check()
        try process.run()
        defer {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        // The random proxy credential is never put in argv or returned to UI.
        try input.fileHandleForWriting.write(contentsOf: Data("proxy = \"http://127.0.0.1:\(port)\"\nproxy-user = \"freev6-test:\(password)\"\n".utf8))
        try? input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while process.isRunning && !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let stats = output.fileHandleForReading.readDataToEndOfFile()
        try? output.fileHandleForReading.close()
        try cancellation.check()
        try verifyListener(port)
        #if DEBUG
        if process.terminationStatus != 0 && process.terminationStatus != 28 {
            FileHandle.standardError.write(Data("download probe curl exit: \(process.terminationStatus)\n".utf8))
        }
        #endif
        guard process.terminationReason == .exit, [0, 28].contains(process.terminationStatus), stats.count < 512,
              let text = String(data: stats, encoding: .utf8) else { throw CoreControllerError.io }
        let parts = text.split(separator: " ")
        guard parts.count == 4, parts[0] == "200", let bytes = Int(parts[1]),
              let total = Double(parts[2]), let first = Double(parts[3]), first > 0, total > first else {
            throw CoreControllerError.invalidResponse
        }
        let result = CoreDownloadResult(bytes: bytes, seconds: total - first)
        try result.validate()
        return result
    }
}
