import CryptoKit
import Foundation

/// A locally signed Flutter client needs an explicit library load constraint because it has no Team ID.
/// The installer pins the exact executable prefix and the kernel-enforced constraint blob.
/// Bundle resource seals may change when the installer or update metadata is embedded.
public enum FlutterClientSeal {
    public static let manifestKey = "FreeV6FlutterClientSeal"
    static let rights = ["com.apple.security.cs.disable-library-validation": true]

    public static func digest(executable: URL) throws -> String {
        let bytes = try InstallationPayload.readSource(executable, limit: InstallationPayload.maximumBinaryBytes)
        func u32(_ offset: Int, big: Bool = false) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw IdentityError.unprotectedCode }
            let indices = big ? [0, 1, 2, 3] : [3, 2, 1, 0]
            return indices.reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
        }
        // Local release supports thin arm64 Mach-O executables only. Frameworks may use fat wrappers.
        guard try u32(0) == 0xfeedfacf, try u32(4) == 0x0100000c, try u32(12) == 2 else {
            throw IdentityError.unprotectedCode
        }
        let commands = try u32(16), end = 32 + (try u32(20))
        guard end <= bytes.count, commands <= (end - 32) / 8 else { throw IdentityError.unprotectedCode }
        var position = 32
        var signature: Range<Int>?
        for _ in 0..<commands {
            let cmd = try u32(position), size = try u32(position + 4)
            guard size >= 8, position + size <= end else { throw IdentityError.unprotectedCode }
            if cmd == 0x1d { // LC_CODE_SIGNATURE
                guard signature == nil, size == 16 else { throw IdentityError.unprotectedCode }
                let offset = try u32(position + 8), length = try u32(position + 12)
                guard offset >= end, length >= 12, offset + length == bytes.count else { throw IdentityError.unprotectedCode }
                signature = offset..<(offset + length)
            }
            position += size
        }
        guard position == end, let signature else { throw IdentityError.unprotectedCode }
        let start = signature.lowerBound, length = try u32(start + 4, big: true), count = try u32(start + 8, big: true)
        guard try u32(start, big: true) == 0xfade0cc0, length >= 12, length <= signature.count,
              count <= (length - 12) / 8 else { throw IdentityError.unprotectedCode }
        var constraint: Range<Int>?
        for index in 0..<count {
            let entry = start + 12 + index * 8
            guard try u32(entry, big: true) == 11 else { continue } // CSSLOT_LIBRARY_CONSTRAINT
            let offset = try u32(entry + 4, big: true)
            guard constraint == nil, offset >= 12 + count * 8, offset + 8 <= length else { throw IdentityError.unprotectedCode }
            let size = try u32(start + offset + 4, big: true)
            guard try u32(start + offset, big: true) == 0xfade8181, size > 8, offset + size <= length else {
                throw IdentityError.unprotectedCode
            }
            constraint = (start + offset)..<(start + offset + size)
        }
        guard let constraint else { throw IdentityError.unprotectedCode }
        var hash = SHA256()
        hash.update(data: bytes[..<start])
        hash.update(data: bytes[constraint])
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
