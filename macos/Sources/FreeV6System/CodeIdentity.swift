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

    private static func inspect(_ staticCode: SecStaticCode) throws -> CodeIdentity {
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let digest = values[kSecCodeInfoUnique as String] as? Data,
              !digest.isEmpty else { throw IdentityError.missingSignature }
        return try CodeIdentity(identifier: identifier, cdHash: digest.map { String(format: "%02x", $0) }.joined())
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw IdentityError.security(status) }
    }
}

public enum IdentityError: Error, LocalizedError {
    case missingCode, missingSignature, invalidIdentity
    case security(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCode: return "无法读取当前进程代码身份"
        case .missingSignature: return "当前进程缺少代码签名摘要"
        case .invalidIdentity: return "无效的代码身份或签名摘要"
        case .security(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Security error \(status)"
        }
    }
}
