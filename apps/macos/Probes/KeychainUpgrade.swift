import CryptoKit
import Foundation
import Security

// Compiled only into the signed update fixture, alongside the product's stores.
// All operations refer to one explicitly opened file. No UI or login keychain.
enum KeychainUpgradeFixture {
    static func run(_ args: [String]) async throws {
        guard args.count == 2, let executable = Bundle.main.executableURL,
              Bundle.main.bundleIdentifier?.hasPrefix("dev.freev6.update-probe.") == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let run = directory.deletingLastPathComponent()
        guard directory.lastPathComponent == "private-keychain-fixture",
              UUID(uuidString: run.lastPathComponent) != nil,
              run.deletingLastPathComponent().lastPathComponent == "native-update-probes",
              executable.resolvingSymlinksInPath().path.hasPrefix(run.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        let file = directory.appendingPathComponent("credentials.keychain-db")
        guard file.resolvingSymlinksInPath().path == file.path else { throw CocoaError(.fileReadInvalidFileName) }
        let password = FileHandle.standardInput.readDataToEndOfFile()
        guard password.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        func check(_ status: OSStatus) throws {
            if status != errSecSuccess { throw CredentialError.security(status) }
        }
        try check(SecKeychainSetUserInteractionAllowed(false))
        var handle: SecKeychain?
        if args[0] == "create" {
            try check(password.withUnsafeBytes { bytes in
                SecKeychainCreate(file.path, UInt32(bytes.count), bytes.baseAddress, false, nil, &handle)
            })
        } else {
            try check(SecKeychainOpen(file.path, &handle))
        }
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        try check(password.withUnsafeBytes { bytes in
            SecKeychainUnlock(handle, UInt32(bytes.count), bytes.baseAddress, true)
        })
        if args[0] == "remove" { try check(SecKeychainDelete(handle)); return }
        if args[0] == "registration-check" {
            let storage = KeychainSecretStorage(service: "dev.freev6.probe.warp", account: "fixture", keychain: handle)
            let registration = WarpRegistration(vault: WarpCredentialVault(storage: storage)) { _, _ in
                throw CocoaError(.executableLoad) // Reaching the simulated remote operation fails the test.
            }
            do {
                _ = try await registration.register(name: "fixture", replacing: nil) { _ in }
                throw CocoaError(.fileWriteUnknown)
            } catch CredentialError.conflict {
                print("\"rejected-existing-record\"")
            } catch CredentialError.security(let status) where [errSecInteractionNotAllowed, errSecAuthFailed].contains(status) {
                print("\"requires-authorization\"")
            }
            return
        }
        guard ["create", "inspect"].contains(args[0]) else { throw CocoaError(.fileReadInvalidFileName) }
        var observations: [String: String] = [:]
        for kind in ["warp", "chain", "cloud"] {
            let storage = KeychainSecretStorage(service: "dev.freev6.probe.\(kind)", account: "fixture", keychain: handle)
            if args[0] == "create" {
                if kind == "warp" {
                    let fixture = try Data(contentsOf: directory.appendingPathComponent("warp-credential.json"))
                    let credential = try JSONDecoder().decode(WarpCredential.self, from: fixture)
                    _ = try await WarpCredentialVault(storage: storage).save(credential, expectedRevision: nil)
                } else {
                    _ = try await ChainProfileKey(storage: storage).load(allowCreation: true)
                }
            }
            do {
                if kind == "warp" {
                    guard let stored = try await WarpCredentialVault(storage: storage).load(interactionAllowed: false) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    _ = try stored.credential.tunnelCredential()
                } else {
                    try await ChainProfileKey(storage: storage).checkAccess(interactionAllowed: false)
                }
                guard let item = try await storage.read(interactionAllowed: false) else { throw CocoaError(.fileNoSuchFile) }
                let digest = Data(SHA256.hash(data: item.data)).base64EncodedString()
                observations[kind] = "\(item.revision.uuidString)/\(digest)"
            } catch CredentialError.security(let status) where status == errSecInteractionNotAllowed {
                observations[kind] = "requires-authorization"
            }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(observations))
    }
}
