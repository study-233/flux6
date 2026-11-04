import Foundation
import Security

public struct CodeIdentity: Codable, Equatable {
    public let identifier: String
    public let cdHash: String

    public var requirement: String { "cdhash H\"\(cdHash)\"" }

    public static func current() throws -> CodeIdentity {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code))
        guard let code else { throw IdentityError.missingCode }
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &staticCode))
        guard let staticCode else { throw IdentityError.missingCode }
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let digest = values[kSecCodeInfoUnique as String] as? Data,
              !digest.isEmpty else { throw IdentityError.missingSignature }
        return CodeIdentity(identifier: identifier, cdHash: digest.map { String(format: "%02x", $0) }.joined())
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw IdentityError.security(status) }
    }
}

public enum IdentityError: Error, LocalizedError {
    case missingCode, missingSignature
    case security(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCode: return "无法读取当前进程代码身份"
        case .missingSignature: return "当前进程缺少代码签名摘要"
        case .security(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Security error \(status)"
        }
    }
}
