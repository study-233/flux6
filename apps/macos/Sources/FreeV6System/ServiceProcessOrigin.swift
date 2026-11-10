import Darwin
import Foundation

/// Origin of the service and its short-lived launchctl commands. Historical
/// PIDs/groups are never signaled. A live old group blocks reconciliation;
/// AbandonProcessGroup is not sufficient to stop a TERM-ignoring child. The
/// core is therefore a separate job directly owned by launchd.
struct ServiceProcessOrigin: Codable, Equatable {
    let bootID: UUID
    let groupID: pid_t
    let ownerUID: uid_t

    static func current() throws -> Self {
        guard getpid() > 1, getppid() == 1, getpgrp() == getpid() else { throw ServiceProcessError.notLaunchdJob }
        return Self(bootID: try bootIdentity(), groupID: getpgrp(), ownerUID: geteuid())
    }

    static func bootIdentity() throws -> UUID {
        var bytes = [CChar](repeating: 0, count: 128)
        var count = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
              count > 1, count <= bytes.count, bytes[count - 1] == 0,
              let value = UUID(uuidString: String(cString: bytes)) else { throw ServiceProcessError.unavailable }
        return value
    }

    func groupHasExited() throws -> Bool {
        guard groupID > 1, ownerUID == geteuid() else { throw ServiceProcessError.invalidOrigin }
        if try Self.bootIdentity() != bootID { return true }
        if groupID == getpgrp() { return false }
        if kill(-groupID, 0) == 0 { return false }
        if errno == ESRCH { return true }
        // EPERM is not proof of termination. Never fall back to a PID kill.
        throw ServiceProcessError.unavailable
    }
}

enum ServiceProcessError: Error, LocalizedError {
    case notLaunchdJob, unavailable, invalidOrigin
    var errorDescription: String? {
        switch self {
        case .notLaunchdJob: return "核心操作必须由 launchd 管理的网络服务执行"
        case .unavailable: return "无法确认旧核心进程已退出，请保留恢复记录"
        case .invalidOrigin: return "核心启动记录的归属无效"
        }
    }
}
