import Darwin
import Foundation

enum CoreEgressError: Error, LocalizedError, Equatable {
    case timedOut(lastExit: Int32?)
    case requestFailed(Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .timedOut(let code):
            return "等待核心网络就绪超时，HTTPS 连接测试未通过" + (code.map { "（curl \($0)）" } ?? "") + "。"
        case .requestFailed(let code): return "HTTPS 连接测试失败（curl \(code)）。"
        case .invalidResponse: return "HTTPS 连接测试未返回有效的 204 响应。"
        }
    }
}

/// mihomo exposes its controller, DNS and TUN before loading providers and
/// entering Running. During that interval it closes external TCP connections.
/// Retry only transient transport failures within one monotonic startup budget;
/// identity, TLS verification, HTTP status and peer routing remain mandatory.
enum CoreEgressCheck {
    static func waitUntilUsable(
        timeout: TimeInterval = 45,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        validateIdentity: () throws -> Void,
        request: (TimeInterval) throws -> CommandResult,
        validatePeer: (String, Bool) throws -> Void
    ) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ChildProcessError.invalidRequest }
        let deadline = now() + timeout
        var lastExit: Int32?
        func remaining() throws -> TimeInterval {
            let value = deadline - now()
            guard value > 0 else { throw CoreEgressError.timedOut(lastExit: lastExit) }
            return value
        }
        while true {
            _ = try remaining()
            try validateIdentity()
            let result = try request(min(8, remaining()))
            try validateIdentity()
            if case .exited(let code) = result.exit, code != 0 { lastExit = code }
            _ = try remaining()
            guard case .exited(let code) = result.exit else { throw NetworkRunError.egressUnavailable }
            if code == 0 {
                let (ip, ipv4) = try peer(result.output)
                try validatePeer(ip, ipv4)
                try validateIdentity()
                _ = try remaining()
                return
            }
            // Never retry certificate failures (60), malformed output or a
            // successful request that used another interface.
            guard [6, 7, 28, 35, 52, 55, 56].contains(code) else { throw CoreEgressError.requestFailed(code) }
            sleep(min(0.25, try remaining()))
        }
    }

    private static func peer(_ output: Data) throws -> (String, Bool) {
        guard let text = String(data: output, encoding: .utf8) else { throw CoreEgressError.invalidResponse }
        let fields = text.split(separator: " ")
        guard fields.count == 2, fields[0] == "204" else { throw CoreEgressError.invalidResponse }
        let ip = String(fields[1])
        var v4 = in_addr(), v6 = in6_addr()
        let ipv4 = inet_pton(AF_INET, ip, &v4) == 1
        guard ipv4 || inet_pton(AF_INET6, ip, &v6) == 1 else { throw CoreEgressError.invalidResponse }
        return (ip, ipv4)
    }
}
