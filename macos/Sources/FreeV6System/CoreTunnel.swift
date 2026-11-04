import Darwin
import Foundation

enum NetworkRunError: Error, LocalizedError {
    case tunnelUnavailable, egressUnavailable, recoveryRequired

    var errorDescription: String? {
        switch self {
        case .tunnelUnavailable: return "无法确认本次核心拥有的 utun 接口"
        case .egressUnavailable: return "未能通过本次隧道完成 HTTPS 出口检查"
        case .recoveryRequired: return "网络会话恢复尚未完成，请检查保留的记录"
        }
    }
}

struct CoreTunnel: Codable, Equatable {
    let name: String
    let index: UInt32

    var valid: Bool {
        let suffix = name.dropFirst(4)
        return index > 0 && name.hasPrefix("utun") && UInt32(suffix).map { String($0) == suffix } == true
    }

    /// Only a utun control socket in the launchd-owned PID identifies the
    /// tunnel. An interface created by some other VPN must never be adopted.
    static func owned(by pid: pid_t) throws -> Self? {
        guard pid > 1 else { throw NetworkRunError.tunnelUnavailable }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let required = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard required > 0, required / stride < 65536 else { throw NetworkRunError.tunnelUnavailable }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: required / stride + 32)
        let count = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard count > 0, Int(count) < fds.count * stride, Int(count) % stride == 0 else { throw NetworkRunError.tunnelUnavailable }
        var found: Self?
        for fd in fds.prefix(Int(count) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: socket))
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size else {
                if errno == EBADF || errno == ENOENT { continue } // Socket closed during enumeration.
                throw NetworkRunError.tunnelUnavailable
            }
            guard socket.psi.soi_kind == SOCKINFO_KERN_CTL else { continue }
            var info = socket.psi.soi_proto.pri_kern_ctl
            let utun = withUnsafeBytes(of: &info.kcsi_name) {
                $0.prefix(while: { $0 != 0 }).elementsEqual("com.apple.net.utun_control".utf8)
            }
            guard utun, info.kcsi_unit > 0 else { continue }
            let name = "utun" + String(info.kcsi_unit - 1)
            let tunnel = Self(name: name, index: if_nametoindex(name))
            guard tunnel.valid, found == nil || found == tunnel else { throw NetworkRunError.tunnelUnavailable }
            found = tunnel
        }
        return found
    }

    func waitForRelease() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while if_nametoindex(name) == index {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NetworkRunError.recoveryRequired }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// A controller handshake proves neither routing nor usable egress. Use a
    /// fixed TLS destination, then check the route to the actual peer address.
    func verifyEgress() throws {
        let http = try CapturedCommand.run(executable: "/usr/bin/curl", arguments: [
            "--disable", "--noproxy", "*", "--silent", "--proto", "=https", "--max-time", "8",
            "--connect-timeout", "4", "--max-filesize", "1024", "--output", "/dev/null",
            "--write-out", "%{http_code} %{remote_ip}", "https://www.gstatic.com/generate_204"
        ], timeout: 10, limit: 256)
        guard http.exit == .exited(0), let text = String(data: http.output, encoding: .utf8) else {
            throw NetworkRunError.egressUnavailable
        }
        let fields = text.split(separator: " ")
        guard fields.count == 2, fields[0] == "204" else { throw NetworkRunError.egressUnavailable }
        let ip = String(fields[1])
        var v4 = in_addr(), v6 = in6_addr()
        let ipv4 = inet_pton(AF_INET, ip, &v4) == 1
        guard ipv4 || inet_pton(AF_INET6, ip, &v6) == 1 else { throw NetworkRunError.egressUnavailable }
        let route = try CapturedCommand.run(executable: "/sbin/route",
            arguments: ["-n", "get", ipv4 ? "-inet" : "-inet6", ip], timeout: 3, limit: 8192)
        guard route.exit == .exited(0), let table = String(data: route.output, encoding: .utf8),
              Self.routeInterfaces(table) == [name], if_nametoindex(name) == index else { throw NetworkRunError.egressUnavailable }
    }

    static func routeInterfaces(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[0] == "interface:" ? String(fields[1]) : nil
        }
    }
}
