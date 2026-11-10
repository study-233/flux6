import Darwin
import Foundation

enum CoreControllerError: Error, Equatable, LocalizedError {
    case notReady, notRunning, identity, invalidRequest, invalidResponse, oversized, timedOut, io
    case rejected(Int), wrongVersion, unconfirmed

    var errorDescription: String? {
        switch self {
        case .notReady: return "核心控制接口尚未就绪"
        case .notRunning: return "当前会话的核心任务未运行"
        case .identity: return "核心控制接口身份不符合当前会话"
        case .invalidRequest: return "核心操作或所选节点无效"
        case .invalidResponse: return "核心控制接口返回了无效响应"
        case .oversized: return "核心控制响应超过大小限制"
        case .timedOut: return "核心控制操作超时，实际状态需重新查询"
        case .io: return "无法完成核心控制通信"
        case .rejected(let code): return "核心拒绝了操作（HTTP \(code)）"
        case .wrongVersion: return "核心版本与固定资源清单不一致"
        case .unconfirmed: return "核心操作结果尚未确认，请重新查询实际状态"
        }
    }
}

struct CoreHTTPResponse {
    let status: Int
    let body: Data
}

/// Only CoreController constructs requests. No generic HTTP method, URL, path,
/// header or body is accepted from an XPC client. Each exchange owns a fresh FD.
final class UnixControllerTransport {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 1024 * 1024
    private let directory: SecureDirectory
    private let currentPID: () throws -> pid_t

    init(directory: SecureDirectory, currentPID: @escaping () throws -> pid_t) {
        self.directory = directory; self.currentPID = currentPID
    }

    func exchange(method: String, target: String, body: Data = Data(), timeout: TimeInterval = 3,
                  firstTrafficSample: Bool = false) throws -> CoreHTTPResponse {
        guard ["GET", "PATCH", "PUT", "DELETE"].contains(method), target.hasPrefix("/"), target.utf8.count <= 1024,
              target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), body.count <= 1024,
              method != "DELETE" || (target == "/proxies/" + CoreController.escaped(SessionNodeGroup.access.coreName) && body.isEmpty),
              timeout.isFinite, timeout > 0, timeout <= 15,
              !firstTrafficSample || (method == "GET" && target == "/traffic" && body.isEmpty) else {
            throw CoreControllerError.invalidRequest
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let pid = try currentPID()
        guard pid > 1 else { throw CoreControllerError.notRunning }
        let before = try socketIdentity()
        let path = directory.path + "/c.sock"
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CoreControllerError.invalidRequest }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreControllerError.io }
        defer { close(fd) }
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw CoreControllerError.io
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                if errno == ENOENT || errno == ECONNREFUSED { throw CoreControllerError.notReady }
                throw CoreControllerError.io
            }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: failure))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else {
                if failure == ENOENT || failure == ECONNREFUSED { throw CoreControllerError.notReady }
                throw CoreControllerError.io
            }
        }
        var uid: uid_t = 0, gid: gid_t = 0, peer: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: peer))
        guard getpeereid(fd, &uid, &gid) == 0, uid == directory.owner,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0,
              size == MemoryLayout.size(ofValue: peer), peer == pid else { throw CoreControllerError.identity }
        let after = try socketIdentity()
        guard before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              try currentPID() == pid else { throw CoreControllerError.identity }

        // HTTP/1.0 and close delimit responses without chunked encoding. This
        // exact wire format is exercised against the pinned Darwin core.
        let header = "\(method) \(target) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        try send(Data(header.utf8) + body, fd: fd, deadline: deadline)
        let response = try receive(fd, deadline: deadline, firstTrafficSample: firstTrafficSample)
        guard try currentPID() == pid else { throw CoreControllerError.unconfirmed }
        return response
    }

    private func socketIdentity() throws -> stat {
        // Reopen the path and compare it to the retained directory descriptor;
        // a renamed/replaced session must never redirect a pathname connect.
        let reopened = try SecureDirectory(path: directory.path, owner: directory.owner)
        try reopened.requirePrivate(); try directory.requirePrivate()
        var expected = stat(), actual = stat(), endpoint = stat()
        guard fstat(directory.descriptor, &expected) == 0, fstat(reopened.descriptor, &actual) == 0,
              expected.st_ino == actual.st_ino, expected.st_dev == actual.st_dev else { throw CoreControllerError.identity }
        guard fstatat(directory.descriptor, "c.sock", &endpoint, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw CoreControllerError.notReady }
            throw CoreControllerError.io
        }
        // Upstream chmods this socket to 0666. Access is isolated by the verified
        // owner-only parent, not by a bearer secret ignored by its Unix listener.
        guard endpoint.st_mode & S_IFMT == S_IFSOCK, endpoint.st_uid == directory.owner else {
            throw CoreControllerError.identity
        }
        return endpoint
    }

    private func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CoreControllerError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw CoreControllerError.io }
            guard result > 0 else { throw CoreControllerError.timedOut }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw CoreControllerError.io }
            // HUP/ERR must be followed by recv/send to consume buffered bytes
            // or get the terminal error, rather than spinning on poll.
            return
        }
    }

    private func send(_ bytes: Data, fd: Int32, deadline: TimeInterval) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let sent = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if sent < 0, errno == EINTR || errno == EAGAIN { continue }
                guard sent > 0 else { throw CoreControllerError.io }
                offset += sent
            }
        }
    }

    private func receive(_ fd: Int32, deadline: TimeInterval, firstTrafficSample: Bool) throws -> CoreHTTPResponse {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        var head: CoreHTTPHead?
        var content = Data()
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count >= 0 else { throw CoreControllerError.io }
            if count == 0 { break }
            if head == nil {
                bytes.append(contentsOf: buffer.prefix(count))
                if let separator = bytes.range(of: Data([13, 10, 13, 10])) {
                    guard separator.upperBound <= Self.maximumHeaderBytes else { throw CoreControllerError.oversized }
                    head = try CoreHTTPHead.decode(Data(bytes[..<separator.lowerBound]))
                    content.append(bytes[separator.upperBound...]); bytes.removeAll()
                } else if bytes.count > Self.maximumHeaderBytes { throw CoreControllerError.oversized }
            } else { content.append(contentsOf: buffer.prefix(count)) }
            guard content.count <= Self.maximumBodyBytes else { throw CoreControllerError.oversized }
            if let head {
                if let length = head.contentLength, content.count > length { throw CoreControllerError.invalidResponse }
                if head.status == 204, !content.isEmpty { throw CoreControllerError.invalidResponse }
                if firstTrafficSample, head.status == 200 {
                    guard head.contentLength == nil else { throw CoreControllerError.invalidResponse }
                    // /traffic is newline-delimited JSON. Return one bounded
                    // sample and close; do not wait for an endless stream's EOF.
                    if let newline = content.firstIndex(of: 10) {
                        guard newline <= 4096 else { throw CoreControllerError.oversized }
                        return CoreHTTPResponse(status: head.status, body: Data(content[..<newline]))
                    }
                    guard content.count <= 4096 else { throw CoreControllerError.oversized }
                }
            }
        }
        guard let head, head.contentLength == nil || head.contentLength == content.count else {
            throw CoreControllerError.invalidResponse
        }
        guard !firstTrafficSample || head.status != 200 else { throw CoreControllerError.invalidResponse }
        return CoreHTTPResponse(status: head.status, body: content)
    }
}

struct CoreHTTPHead {
    let status: Int
    let contentLength: Int?

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= UnixControllerTransport.maximumHeaderBytes,
              let text = String(data: bytes, encoding: .ascii) else { throw CoreControllerError.invalidResponse }
        let lines = text.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusLine.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(statusLine[0]),
              statusLine[1].utf8.count == 3, statusLine[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(statusLine[1]), (200...599).contains(status), lines.count <= 128,
              lines.allSatisfy({ $0.utf8.allSatisfy { $0 == 9 || (32...126).contains($0) } }) else {
            throw CoreControllerError.invalidResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw CoreControllerError.invalidResponse }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw CoreControllerError.invalidResponse }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity" else {
            throw CoreControllerError.invalidResponse
        }
        var length: Int?
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value),
                  number <= UnixControllerTransport.maximumBodyBytes else { throw CoreControllerError.oversized }
            length = number
        }
        guard status != 204 || length == nil || length == 0 else { throw CoreControllerError.invalidResponse }
        return Self(status: status, contentLength: length)
    }
}
