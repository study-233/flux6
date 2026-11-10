import Darwin
import Foundation
import XCTest
@testable import FreeV6System

final class RegistrationFileTests: XCTestCase {
    private func withRecord(_ body: (URL, CodeIdentity, ServiceRegistration) throws -> Void) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/registration-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try CodeIdentity(identifier: "service", cdHash: String(repeating: "a", count: 40))
        let record = try ServiceRegistration(service: identity, clients: [RegisteredClient(uid: geteuid(), identity: identity)])
        let file = directory.appendingPathComponent("record.json")
        try JSONEncoder().encode(record).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        try body(file, identity, record)
    }

    func testReadsTrustedRecordAndRejectsDifferentServiceOrOwner() throws {
        try withRecord { file, identity, record in
            XCTAssertEqual(try RegistrationFile.load(path: file.path, owner: geteuid(), service: identity), record)
            let other = try CodeIdentity(identifier: "other", cdHash: String(repeating: "b", count: 40))
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid(), service: other))
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid() + 1, service: identity))
        }
    }

    func testRejectsWritableFileAndDirectory() throws {
        try withRecord { file, identity, _ in
            XCTAssertEqual(chmod(file.path, 0o622), 0)
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid(), service: identity))
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            XCTAssertEqual(chmod(file.deletingLastPathComponent().path, 0o722), 0)
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid(), service: identity))
        }
    }

    func testRejectsSymlinksAndHardLinks() throws {
        try withRecord { file, identity, _ in
            let alias = file.deletingLastPathComponent().appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            XCTAssertThrowsError(try RegistrationFile.load(path: alias.path, owner: geteuid(), service: identity))
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file.deletingLastPathComponent())
            XCTAssertThrowsError(try RegistrationFile.load(path: alias.appendingPathComponent("record.json").path,
                                                          owner: geteuid(), service: identity))
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.linkItem(at: file, to: alias)
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid(), service: identity))
        }
    }

    func testRejectsOversizedRecordAndFIFOWithoutBlocking() throws {
        try withRecord { file, identity, _ in
            try Data(repeating: 32, count: ServiceRegistration.maximumBytes + 1).write(to: file)
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid(), service: identity))
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            XCTAssertThrowsError(try RegistrationFile.load(path: file.path, owner: geteuid(), service: identity))
        }
    }
}
