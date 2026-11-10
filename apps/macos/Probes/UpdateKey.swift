// Ephemeral probe keys only. Release signing keys use a separate process.
import CryptoKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let key = Curve25519.Signing.PrivateKey()
let descriptor = open(CommandLine.arguments[1], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
guard descriptor >= 0 else { exit(3) }
let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
try handle.write(contentsOf: Data(key.rawRepresentation.base64EncodedString().utf8))
try handle.close()
print(key.publicKey.rawRepresentation.base64EncodedString())
