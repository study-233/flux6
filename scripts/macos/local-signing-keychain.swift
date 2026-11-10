// Build-time tool only. Owns one dedicated signing keychain; no login Keychain
// items, default keychain, trust settings or persistent search list are changed.
import Foundation
import Security

func check(_ value: OSStatus) throws {
    guard value == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(value)) }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2, ["create", "unlock"].contains(args[0]) else { exit(2) }
    let root = URL(fileURLWithPath: args[1])
    let password = try Data(contentsOf: root.appendingPathComponent("password"))
    guard password.count >= 32, password.count <= 256 else { exit(2) }
    let path = root.appendingPathComponent("signing.keychain-db").path
    var keychain: SecKeychain?
    var oldSearch: CFArray?
    try check(SecKeychainCopySearchList(&oldSearch))
    defer { if let oldSearch { SecKeychainSetSearchList(oldSearch) } }
    var interaction = DarwinBoolean(false)
    try check(SecKeychainGetUserInteractionAllowed(&interaction))
    try check(SecKeychainSetUserInteractionAllowed(false))
    defer { SecKeychainSetUserInteractionAllowed(interaction.boolValue) }
    if args[0] == "create" {
        try password.withUnsafeBytes { bytes in
            try check(SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain))
        }
        guard let keychain else { exit(2) }
        var trusted: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted))
        guard let trusted else { exit(2) }
        var access: SecAccess?
        try check(SecAccessCreate("Flux6 local build signing" as CFString, [trusted] as CFArray, &access))
        guard let access else { exit(2) }
        let p12 = try Data(contentsOf: root.appendingPathComponent("identity.p12"))
        let options: [String: Any] = [kSecImportExportPassphrase as String: String(decoding: password, as: UTF8.self),
            kSecImportExportKeychain as String: keychain, kSecImportExportAccess as String: access]
        var imported: CFArray?
        try check(SecPKCS12Import(p12 as CFData, options as CFDictionary, &imported))
    } else {
        try check(SecKeychainOpen(path, &keychain))
        guard let keychain else { exit(2) }
        try password.withUnsafeBytes { bytes in
            try check(SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true))
        }
    }
    // Limit the unlocked build window. Each build explicitly unlocks this
    // keychain; the random password never appears in command-line arguments.
    var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: true,
                                       useLockInterval: true, lockInterval: 3600)
    try check(SecKeychainSetSettings(keychain, &settings))
} catch {
    fputs("Local signing keychain operation failed: \((error as NSError).code)\n", stderr)
    exit(1)
}
