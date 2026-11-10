import Foundation
import Security

public enum UpdateHost {
    public static func enclosingBundle(agent: Bundle = .main) throws -> Bundle {
        let location = agent.bundleURL
        let root = location.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard location.lastPathComponent == "FreeV6UpdateAgent.app",
              location.deletingLastPathComponent().lastPathComponent == "Helpers",
              let host = Bundle(url: root), root.pathExtension == "app",
              host.executableURL?.lastPathComponent == "FreeV6" else { throw UpdateFailure.invalidHost }
        try verify(host.bundleURL)
        return host
    }

    public static func verify(_ bundle: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw UpdateFailure.invalidHost
        }
    }

    public static func requireParent(of host: Bundle) throws {
        var running: SecCode?
        guard getppid() > 1,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: getppid())] as CFDictionary, [], &running) == errSecSuccess,
              let running else { throw UpdateFailure.invalidHost }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &staticCode) == errSecSuccess, let staticCode else { throw UpdateFailure.invalidHost }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
              executable.resolvingSymlinksInPath() == host.executableURL?.resolvingSymlinksInPath(),
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else { throw UpdateFailure.invalidHost }
        var installed: SecStaticCode?
        var installedInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(host.bundleURL as CFURL, [], &installed) == errSecSuccess, let installed,
              SecCodeCopySigningInformation(installed, SecCSFlags(rawValue: kSecCSSigningInformation), &installedInfo) == errSecSuccess,
              let onDisk = installedInfo as? [String: Any],
              let runningDigest = values[kSecCodeInfoUnique as String] as? Data,
              runningDigest == onDisk[kSecCodeInfoUnique as String] as? Data else { throw UpdateFailure.invalidHost }
    }
}
