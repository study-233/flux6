import Foundation
import Security

public struct CodeIdentity: Codable, Equatable {
    public let identifier: String
    public let cdHash: String

    public var requirement: String { "cdhash H\"\(cdHash)\"" }

    public init(identifier: String, cdHash: String) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 255,
              cdHash.count == 40,
              cdHash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw IdentityError.invalidIdentity
        }
        self.identifier = identifier
        self.cdHash = cdHash
    }

    private enum CodingKeys: String, CodingKey { case identifier, cdHash }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: values.decode(String.self, forKey: .identifier),
                      cdHash: values.decode(String.self, forKey: .cdHash))
    }

    public static func current() throws -> CodeIdentity {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code))
        guard let code else { throw IdentityError.missingCode }
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &staticCode))
        guard let staticCode else { throw IdentityError.missingCode }
        return try inspect(staticCode)
    }

    public static func file(at url: URL) throws -> CodeIdentity {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw IdentityError.missingCode }
        try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil))
        return try inspect(code)
    }

    public static func protectedFile(at url: URL, identifier: String? = nil, checkResources: Bool = true,
                                     trustedClientSeal: String? = nil) throws -> CodeIdentity {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw IdentityError.missingCode }
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if !checkResources { flags |= kSecCSDoNotValidateResources }
        try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), nil))
        let values = try information(code)
        let identity = try inspect(code)
        guard identifier == nil || identity.identifier == identifier else { throw IdentityError.invalidIdentity }
        let runtimeFlags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let rights = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        // Both ad-hoc and certificate-signed local hosts lack a Team ID.
        // This exception is authorized only by the exact installer-pinned
        // executable and kernel library constraint, independent of signer type.
        if trustedClientSeal != nil || (identity.identifier == "dev.freev6.desktop" && !rights.isEmpty) {
            guard identity.identifier == "dev.freev6.desktop", runtimeFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
                  rights as? [String: Bool] == FlutterClientSeal.rights,
                  let executable = values[kSecCodeInfoMainExecutable as String] as? URL else { throw IdentityError.unprotectedCode }
            let expected = try trustedClientSeal ?? installerClientSeal(at: url.appendingPathComponent("Contents/Helpers/freev6-service-installer"))
            guard let expected, expected.count == 64, try FlutterClientSeal.digest(executable: executable) == expected else {
                throw IdentityError.unprotectedCode
            }
        } else {
            try RuntimeProtection.validate(flags: runtimeFlags, entitlements: rights)
        }
        return identity
    }

    /// Read the fixed client program/constraint fingerprint from an independently validated installer.
    static func installerClientSeal(at installer: URL) throws -> String? {
        _ = try protectedFile(at: installer, identifier: "dev.freev6.service-installer")
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(installer as CFURL, [], &code))
        guard let code else { throw IdentityError.missingCode }
        let info = try information(code)[kSecCodeInfoPList as String] as? [String: Any]
        return info?[FlutterClientSeal.manifestKey] as? String
    }

    /// Security's signed Info.plist and executable URL, not mutable Bundle metadata.
    public static func currentSigningInformation() throws -> [String: Any] {
        var current: SecCode?
        try check(SecCodeCopySelf([], &current))
        guard let current else { throw IdentityError.missingCode }
        try check(SecCodeCheckValidity(current, [], nil))
        var code: SecStaticCode?
        try check(SecCodeCopyStaticCode(current, [], &code))
        guard let code else { throw IdentityError.missingCode }
        return try information(code)
    }

    private static func inspect(_ staticCode: SecStaticCode) throws -> CodeIdentity {
        let values = try information(staticCode)
        guard let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let digest = values[kSecCodeInfoUnique as String] as? Data,
              !digest.isEmpty else { throw IdentityError.missingSignature }
        return try CodeIdentity(identifier: identifier, cdHash: digest.map { String(format: "%02x", $0) }.joined())
    }

    private static func information(_ staticCode: SecStaticCode) throws -> [String: Any] {
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let values = information as? [String: Any] else { throw IdentityError.missingSignature }
        return values
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw IdentityError.security(status) }
    }
}

public enum RuntimeProtection {
    public static func validate(flags: UInt32, entitlements: [String: Any]) throws {
        guard flags & SecCodeSignatureFlags.runtime.rawValue != 0 else { throw IdentityError.unprotectedCode }
        // Privileged helpers, Team-signed hosts, and legacy clients need no entitlements.
        // The separately pinned local Flutter client is checked before this common path.
        guard entitlements.isEmpty else { throw IdentityError.unprotectedCode }
    }
}

public enum IdentityError: Error, LocalizedError {
    case missingCode, missingSignature, invalidIdentity, unprotectedCode
    case security(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCode: return "无法读取当前进程代码身份"
        case .missingSignature: return "当前进程缺少代码签名摘要"
        case .invalidIdentity: return "无效的代码身份或签名摘要"
        case .unprotectedCode: return "服务客户端必须启用严格的运行期代码保护"
        case .security(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Security error \(status)"
        }
    }
}
