import Foundation
import Security
import FreeV6System

do {
    let info = try CodeIdentity.currentSigningInformation()
    guard let signedPlist = info[kSecCodeInfoPList as String] as? [String: Any],
          let digest = signedPlist["FreeV6ServiceSHA256"] as? String,
          digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }),
          let executable = info[kSecCodeInfoMainExecutable as String] as? URL else {
        throw InstallationError.invalidPayload
    }
    let identity = try CodeIdentity.protectedFile(at: executable, identifier: "dev.freev6.service-installer")
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["manifest"] {
        let result: [String: Any] = ["serviceSHA256": digest, "protocolVersion": ServiceProtocolVersion.current,
                                   "installer": ["identifier": identity.identifier, "cdHash": identity.cdHash]]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
    } else {
        guard geteuid() == 0 else { throw InstallationError.invalidPayload }
        switch arguments.first {
        case "install" where arguments.count == 4:
            let app = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
            guard app.pathExtension == "app", app.deletingLastPathComponent().path == "/Applications",
                  let uid = UInt32(arguments[2]), uid >= 500, getpwuid(uid) != nil else { throw InstallationError.invalidPayload }
            try SystemServiceInstaller.install(app: app, clientHash: arguments[3], uid: uid, serviceHash: digest,
                                               installer: executable, installerIdentity: identity)
            print("installed")
        case "uninstall" where arguments.count == 1:
            try SystemServiceInstaller.uninstall()
            print("uninstalled")
        case "recover" where arguments.count == 1:
            try SystemServiceInstaller.recover()
            print("recovered")
        default: throw InstallationError.invalidPayload
        }
    }
} catch {
    fputs("freev6-service-installer: \(error.localizedDescription)\n", stderr)
    exit(1)
}
