import Foundation

public enum ServiceInstallationAction: String { case install, uninstall, recover }

public struct ServiceInstallationRequest {
    public let executable: URL
    public let arguments: [String]

    public init(action: ServiceInstallationAction, app: URL, uid: UInt32, clientHash: String) throws {
        let normalized = app.standardizedFileURL.resolvingSymlinksInPath()
        guard normalized.pathExtension == "app", normalized.deletingLastPathComponent().path == "/Applications" else {
            throw ServiceSetupError.moveToApplications
        }
        _ = try CodeIdentity(identifier: "dev.freev6.desktop", cdHash: clientHash)
        guard uid >= 500 else { throw InstallationError.invalidPayload }
        if action == .install {
            executable = normalized.appendingPathComponent("Contents/Helpers/freev6-service-installer")
            arguments = ["install", normalized.path, String(uid), clientHash]
        } else {
            let recovery = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/dev.freev6.service-installer")
            executable = FileManager.default.fileExists(atPath: recovery.path) ? recovery : normalized.appendingPathComponent("Contents/Helpers/freev6-service-installer")
            arguments = [action.rawValue]
        }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public var appleScript: String {
        let command = ([executable.path] + arguments).map(Self.shellQuote).joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return "do shell script \"\(literal)\" with administrator privileges"
    }

    /// Run off the main thread. The system handles credentials; they never enter
    /// the application, its arguments, logs or persistent storage.
    public func execute() throws {
        _ = try CodeIdentity.protectedFile(at: executable, identifier: "dev.freev6.service-installer")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        // The helper emits one bounded status/error line. Drain before waiting.
        let bytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: bytes.prefix(4096), as: UTF8.self)
            if message.contains("(-128)") { throw ServiceSetupError.cancelled }
            throw ServiceSetupError.failed(message)
        }
    }
}

public enum ServiceSetupError: Error, LocalizedError {
    case moveToApplications, cancelled, failed(String)
    public var errorDescription: String? {
        switch self {
        case .moveToApplications: return "请先将 FreeV6.app 移入“应用程序”，重新打开后再安装网络服务。"
        case .cancelled: return "已取消管理员授权"
        case .failed(let message): return "服务操作未完成：\(message)"
        }
    }
}

public enum InstalledServiceStatus {
    public static func check() throws -> HandshakeReply? {
        guard let identity = try identity() else { return nil }
        return try ServiceClient.handshake(identity: identity)
    }

    public static func identity() throws -> CodeIdentity? {
        let paths = [ServicePaths.executable, ServicePaths.registration, ServicePaths.launchDaemon,
                     "/Library/PrivilegedHelperTools/dev.freev6.service-installer"]
        let present = paths.map { FileManager.default.fileExists(atPath: $0) }
        if present.allSatisfy({ !$0 }) { return nil }
        guard present.allSatisfy({ $0 }) else { throw InstallationError.inconsistentInstallation }
        let identity = try CodeIdentity.protectedFile(at: URL(fileURLWithPath: ServicePaths.executable), identifier: ServiceProtocolVersion.machService)
        _ = try RegistrationFile.load(path: ServicePaths.registration, owner: 0, service: identity)
        return identity
    }
}
