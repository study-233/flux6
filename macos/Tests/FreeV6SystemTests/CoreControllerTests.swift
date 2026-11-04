import Darwin
import Foundation
import XCTest
@testable import FreeV6System

final class CoreControllerTests: XCTestCase {
    private func withServer(_ replies: [ControllerTestServer.Reply], _ body: (ControllerTestServer, CoreController) throws -> Void) throws {
        let server = try ControllerTestServer(replies: replies)
        defer { server.stop() }
        let client = try CoreController(probeDirectory: server.directory, currentPID: { getpid() })
        try body(server, client)
    }

    func testHTTPHeadersRejectAmbiguousOrUnsupportedFraming() throws {
        let head = try CoreHTTPHead.decode(Data("HTTP/1.0 200 OK\r\nContent-Length: 12\r\nDate: fixed".utf8))
        XCTAssertEqual(head.status, 200); XCTAssertEqual(head.contentLength, 12)
        XCTAssertNil(try CoreHTTPHead.decode(Data("HTTP/1.0 200 OK".utf8)).contentLength)
        for value in ["", "HTTP/2 200 OK", "HTTP/1.0 100 Continue", "HTTP/1.0 +200 OK",
                      "HTTP/1.0 200 OK\nBad: a", "HTTP/1.0 200 OK\r\n Content-Length: 3",
                      "HTTP/1.0 200 OK\r\nContent-Length: 3\r\ncontent-length: 3",
                      "HTTP/1.0 200 OK\r\nContent-Length: -1", "HTTP/1.0 200 OK\r\nContent-Length: 1048577",
                      "HTTP/1.0 200 OK\r\nContent-Length: 3, 3", "HTTP/1.0 200 OK\r\nContent-Length: 1e2",
                      "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked", "HTTP/1.0 200 OK\r\nContent-Encoding: gzip",
                      "HTTP/1.0 204 No Content\r\nContent-Length: 1", "HTTP/1.0 200 OK\r\nName: bad\0value"] {
            XCTAssertThrowsError(try CoreHTTPHead.decode(Data(value.utf8)), value)
        }
    }

    func testFragmentedResponseAndCloseDelimitedJSONReachTypedModels() throws {
        let version = ControllerTestServer.json(["version": ApprovedResourceCatalog.coreVersion], fragmented: true)
        let counters = Data("HTTP/1.0 200 OK\r\n\r\n{\"uploadTotal\":18446744073709551615,\"downloadTotal\":6,\"connections\":[{\"secret\":\"do-not-export\"}]}".utf8)
        try withServer([version, .init(bytes: counters)]) { server, client in
            XCTAssertEqual(try client.version(), ApprovedResourceCatalog.coreVersion)
            XCTAssertEqual(try client.trafficTotals(), .init(uploadTotal: UInt64.max, downloadTotal: 6))
            XCTAssertEqual(server.requests.count, 2)
            XCTAssertTrue(server.requests[0].starts(with: Data("GET /version HTTP/1.0\r\n".utf8)))
            XCTAssertTrue(String(decoding: server.requests[0], as: UTF8.self).contains("Connection: close\r\n"))
        }
    }

    func testTruncatedOversizedAndExtraResponseBytesFail() throws {
        let cases = [
            Data("HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\n{}".utf8),
            Data("HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\n{}".utf8),
            Data("HTTP/1.0 204 No Content\r\n\r\nx".utf8),
            Data("HTTP/1.0 200 OK\r\nIncomplete: 1".utf8),
            Data("HTTP/1.0 200 OK\r\nX-Test: ".utf8) + Data(repeating: 65, count: 16_384),
            Data("HTTP/1.0 200 OK\r\n\r\n".utf8) + Data(repeating: 65, count: 1_048_577),
        ]
        for response in cases {
            try withServer([.init(bytes: response)]) { server, _ in
                let transport = UnixControllerTransport(directory: server.directory, currentPID: { getpid() })
                XCTAssertThrowsError(try transport.exchange(method: "GET", target: "/version"))
            }
        }
    }

    func testTrafficReadsOneBoundedLineWithoutWaitingForStreamToClose() throws {
        let header = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n".utf8)
        let sample = Data("{\"up\":1,\"down\":2,\"upTotal\":3,\"downTotal\":4}\n".utf8)
        try withServer([.init(bytes: header + sample + sample, holdOpen: 0.5)]) { _, client in
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try client.trafficSample(), .init(up: 1, down: 2, upTotal: 3, downTotal: 4))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.4)
        }
        for bytes in [header + sample.dropLast(), header + Data(repeating: 65, count: 4097),
                      header + Data("{\"up\":-1,\"down\":0,\"upTotal\":0,\"downTotal\":0}\n".utf8)] {
            try withServer([.init(bytes: bytes)]) { _, client in XCTAssertThrowsError(try client.trafficSample()) }
        }
    }

    func testPeerMustMatchBeforeSendingAndJobMustStillMatchAfterResponse() throws {
        try withServer([]) { server, _ in
            let client = try CoreController(probeDirectory: server.directory, currentPID: { getpid() + 1 })
            XCTAssertThrowsError(try client.version()) { XCTAssertEqual($0 as? CoreControllerError, .identity) }
            XCTAssertTrue(server.requests.isEmpty)
        }
        try withServer([ControllerTestServer.json(["version": ApprovedResourceCatalog.coreVersion])]) { server, _ in
            var calls = 0
            let client = try CoreController(probeDirectory: server.directory, currentPID: {
                calls += 1; return calls <= 2 ? getpid() : getpid() + 1
            })
            XCTAssertThrowsError(try client.version()) { XCTAssertEqual($0 as? CoreControllerError, .unconfirmed) }
        }
    }

    func testSocketRequiresPrivateUnreplacedParentAndRejectsLinksAndRegularFiles() throws {
        try withServer([]) { server, client in
            XCTAssertEqual(chmod(server.root.path, 0o711), 0)
            XCTAssertThrowsError(try client.version())
            XCTAssertEqual(chmod(server.root.path, 0o700), 0)
            let endpoint = server.root.appendingPathComponent("c.sock")
            let alternate = server.root.appendingPathComponent("original.sock")
            try FileManager.default.moveItem(at: endpoint, to: alternate)
            try FileManager.default.createSymbolicLink(at: endpoint, withDestinationURL: alternate)
            XCTAssertThrowsError(try client.version()) { XCTAssertEqual($0 as? CoreControllerError, .identity) }
            try FileManager.default.removeItem(at: endpoint)
            try Data().write(to: endpoint)
            XCTAssertThrowsError(try client.version()) { XCTAssertEqual($0 as? CoreControllerError, .identity) }
            XCTAssertTrue(server.requests.isEmpty)
        }
        try withServer([]) { server, client in
            let moved = server.root.appendingPathExtension("old")
            try FileManager.default.moveItem(at: server.root, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            try FileManager.default.createDirectory(at: server.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            XCTAssertThrowsError(try client.version()) { XCTAssertEqual($0 as? CoreControllerError, .identity) }
        }
    }

    func testDeadlineAndMissingSocketReadinessAreBounded() throws {
        try withServer([.init(bytes: Data(), delay: 0.2)]) { server, _ in
            let transport = UnixControllerTransport(directory: server.directory, currentPID: { getpid() })
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try transport.exchange(method: "GET", target: "/version", timeout: 0.04)) {
                XCTAssertEqual($0 as? CoreControllerError, .timedOut)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        }
        try withServer([]) { server, client in
            try FileManager.default.removeItem(at: server.root.appendingPathComponent("c.sock"))
            XCTAssertThrowsError(try client.waitUntilReady(timeout: 0.06)) { XCTAssertEqual($0 as? CoreControllerError, .timedOut) }
            for value in [0.0, -1, .nan, .infinity, 31] { XCTAssertThrowsError(try client.waitUntilReady(timeout: value)) }
        }
    }

    func testModeWriteUsesOnlyModeAndReadsBackBeforeSuccess() throws {
        try withServer([.noContent, ControllerTestServer.json(["mode": "global", "secret": "private"]),
                        .noContent, ControllerTestServer.json(["mode": "direct"])]) { server, client in
            try client.setMode(.global)
            XCTAssertEqual(try requestBody(server.requests[0]), ["mode": "global"])
            XCTAssertTrue(server.requests[0].starts(with: Data("PATCH /configs HTTP/1.0\r\n".utf8)))
            XCTAssertThrowsError(try client.setMode(.rule)) { XCTAssertEqual($0 as? CoreControllerError, .unconfirmed) }
        }
    }

    func testSelectionIsLimitedToKnownMembersEscapesNamesAndReadsBack() throws {
        let name = "选择 / 50%2F?&"
        func group(_ now: String) -> ControllerTestServer.Reply {
            ControllerTestServer.json(["name": name, "type": "Selector", "all": ["DIRECT", "REJECT"], "now": now])
        }
        try withServer([group("DIRECT"), .noContent, group("REJECT"), group("REJECT")]) { server, client in
            try client.select(group: name, member: "REJECT")
            XCTAssertTrue(server.requests[1].starts(with: Data("PUT /proxies/%E9%80%89%E6%8B%A9%20%2F%2050%252F%3F%26 HTTP/1.0\r\n".utf8)))
            XCTAssertEqual(try requestBody(server.requests[1]), ["name": "REJECT"])
            XCTAssertThrowsError(try client.select(group: name, member: "unknown")) { XCTAssertEqual($0 as? CoreControllerError, .invalidRequest) }
            XCTAssertEqual(server.requests.count, 4) // Invalid member causes only a read.
            for invalid in ["", "name\r\nPATCH /configs", String(repeating: "x", count: 129)] {
                XCTAssertThrowsError(try client.select(group: invalid, member: "DIRECT"))
                XCTAssertThrowsError(try client.measureDelay(name: invalid))
            }
            XCTAssertEqual(server.requests.count, 4)
        }
    }

    func testDelayHasFixedDestinationAndStructuredFailureResults() throws {
        let node = ControllerTestServer.json(["name": "REJECT", "type": "Reject"])
        try withServer([node, ControllerTestServer.json(["delay": 19]), node, .status(503), node, .status(504),
                        node, ControllerTestServer.json(["delay": 0])]) { server, client in
            XCTAssertEqual(try client.measureDelay(name: "REJECT"), .measured(milliseconds: 19))
            XCTAssertTrue(server.requests[1].starts(with: Data("GET /proxies/REJECT/delay?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204 HTTP/1.0\r\n".utf8)))
            XCTAssertEqual(try client.measureDelay(name: "REJECT"), .unavailable)
            XCTAssertEqual(try client.measureDelay(name: "REJECT"), .timedOut)
            XCTAssertThrowsError(try client.measureDelay(name: "REJECT")) { XCTAssertEqual($0 as? CoreControllerError, .invalidResponse) }
        }
    }

    func testVersionResponseModelsAndErrorsDoNotLeakRawCoreData() throws {
        let malformed: [[String: Any]] = [
            ["proxies": [:]], ["proxies": ["name": ["name": "other", "type": "Direct"]]],
            ["proxies": ["name": ["name": "name", "type": "Selector", "all": ["DIRECT"], "now": "unknown"]]],
            ["proxies": ["name": ["name": "name", "type": "Selector", "all": ["DIRECT", "DIRECT"]]]],
        ]
        for value in malformed {
            try withServer([ControllerTestServer.json(value)]) { _, client in
                XCTAssertThrowsError(try client.proxies()) { XCTAssertEqual($0 as? CoreControllerError, .invalidResponse) }
            }
        }
        try withServer([ControllerTestServer.json(["version": "unexpected"]), .status(500, body: "private-credential"),
                        ControllerTestServer.json(["uploadTotal": -1, "downloadTotal": 0])]) { _, client in
            XCTAssertThrowsError(try client.version()) { XCTAssertEqual($0 as? CoreControllerError, .wrongVersion) }
            XCTAssertThrowsError(try client.mode()) {
                XCTAssertEqual($0 as? CoreControllerError, .rejected(500))
                XCTAssertFalse($0.localizedDescription.contains("private-credential"))
            }
            XCTAssertThrowsError(try client.trafficTotals()) { XCTAssertEqual($0 as? CoreControllerError, .invalidResponse) }
        }
    }

    private func requestBody(_ bytes: Data) throws -> [String: String] {
        let range = try XCTUnwrap(bytes.range(of: Data([13, 10, 13, 10])))
        return try JSONDecoder().decode([String: String].self, from: bytes[range.upperBound...])
    }
}

/// A bounded, no-IP wire fixture. It uses the test process as the Unix peer so
/// production getpeereid/LOCAL_PEERPID checks run unchanged. Every socket and
/// worker is closed/joined before removing its private test directory.
private final class ControllerTestServer: @unchecked Sendable {
    struct Reply {
        let bytes: Data
        var fragmented = false
        var delay: TimeInterval = 0
        var holdOpen: TimeInterval = 0
        static let noContent = Reply(bytes: Data("HTTP/1.0 204 No Content\r\n\r\n".utf8))
        static func status(_ status: Int, body: String = "") -> Self {
            .init(bytes: Data("HTTP/1.0 \(status) Test\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        }
    }
    let root: URL
    let directory: SecureDirectory
    private let listener: Int32
    private let replies: [Reply]
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var stopping = false
    private var recorded: [Data] = []
    var requests: [Data] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func json(_ object: [String: Any], fragmented: Bool = false) -> Reply {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Reply(bytes: Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload,
                     fragmented: fragmented)
    }

    init(replies: [Reply]) throws {
        guard geteuid() != 0 else { throw XCTSkip("Controller fixtures require an ordinary user") }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = repository.appendingPathComponent("build/cc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = try SecureDirectory(path: root.path, owner: geteuid())
        self.replies = replies
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = root.path + "/c.sock"
        guard path.utf8.count < 104 else { close(listener); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw POSIXError(.EIO) }
        DispatchQueue.global().async { self.serve(); self.done.signal() }
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
        close(listener)
        try? FileManager.default.removeItem(at: root)
    }

    private func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    private func serve() {
        var index = 0
        while !shouldStop() {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 20) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            if let request = readRequest(fd) {
                lock.lock(); recorded.append(request); lock.unlock()
                if index < replies.count {
                    let reply = replies[index]; index += 1
                    if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    reply.bytes.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count, !shouldStop(), ProcessInfo.processInfo.systemUptime < deadline {
                            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            guard poll(&poller, 1, 20) > 0 else { continue }
                            let amount = reply.fragmented ? 1 : buffer.count - offset
                            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), amount, 0)
                            if count < 0, errno == EAGAIN || errno == EINTR { continue }
                            if count <= 0 { break }
                            offset += count
                        }
                    }
                    if reply.holdOpen > 0 { Thread.sleep(forTimeInterval: reply.holdOpen) }
                }
            }
            close(fd)
        }
    }

    private func readRequest(_ fd: Int32) -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while !shouldStop(), ProcessInfo.processInfo.systemUptime < deadline, bytes.count <= 8192 {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 20) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
            if let separator = bytes.range(of: Data([13, 10, 13, 10])),
               let text = String(data: bytes[..<separator.lowerBound], encoding: .utf8),
               let line = text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Content-Length: ") }),
               let length = Int(line.dropFirst(16)), bytes.count == separator.upperBound + length { return bytes }
        }
        return nil
    }
}
