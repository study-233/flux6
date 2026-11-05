// Release-key check. Private material arrives only through stdin.
import CryptoKit
import Foundation
import Darwin

guard CommandLine.arguments.count == 2,
      let expected = Data(base64Encoded: CommandLine.arguments[1]) else { exit(2) }
let bytes = try FileHandle.standardInput.read(upToCount: 256) ?? Data()
guard let text = String(data: bytes, encoding: .utf8),
      let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { exit(3) }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
guard key.publicKey.rawRepresentation == expected else { exit(4) }
