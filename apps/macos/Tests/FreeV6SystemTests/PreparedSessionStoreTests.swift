import Darwin
import Foundation
import XCTest
import FreeV6Configuration
@testable import FreeV6System

final class PreparedSessionStoreTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        // Keep the actual Unix socket path within Darwin's 104-byte limit.
        let root = repository.appendingPathComponent("build/n-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func request() throws -> ConfigurationCheckRequest {
        let business = try JSONDecoder().decode(BusinessConfiguration.self,
            from: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-business-configuration.json")))
        return ConfigurationCheckRequest(runtimeID: ApprovedResourceCatalog.native.first { $0.architecture != nil }!.id,
            geodataID: String(ApprovedResourceCatalog.native.first { $0.architecture == nil }!.id.split(separator: "/")[0]),
            settingsRevision: 29, credentialRevision: UUID(), configuration: business)
    }
    private func install(_ store: ServiceResourceStore) throws {
        guard let runtime = ProcessInfo.processInfo.environment["FREEV6_RUNTIME_FIXTURES_DIR"],
              let geodata = ProcessInfo.processInfo.environment["FREEV6_GEODATA_FIXTURES_DIR"] else {
            throw XCTSkip("Set official runtime and geodata fixture directories")
        }
        for asset in ApprovedResourceCatalog.native {
            let file = URL(fileURLWithPath: asset.architecture == nil ? geodata : runtime)
                .appendingPathComponent(asset.archiveName ?? String(asset.id.split(separator: "/")[1]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            _ = try store.install(id: asset.id, source: handle, clientUID: geteuid())
        }
    }
    private func leavePartial(_ sessions: PreparedSessionStore) throws -> PreparedSessionRecord {
        XCTAssertThrowsError(try sessions.prepare(request(), clientUID: geteuid()) { directory in
            try directory.write("country.mmdb", data: Data("partial file".utf8), mode: 0o400)
            throw POSIXError(.ENOSPC)
        }) { error in XCTAssertEqual((error as? POSIXError)?.code, .ENOSPC) }
        let record = try XCTUnwrap(sessions.current())
        XCTAssertEqual(record.phase, .preparing)
        return record
    }

    func testRealResourceCopiesConfigurationBindingIsolationAndCleanup() throws {
        try fixture { root in
            let resources = try ServiceResourceStore(path: root.appendingPathComponent("resources").path, owner: geteuid())
            try install(resources)
            let sessions = try PreparedSessionStore(path: root.path, owner: geteuid())
            let request = try request()
            let record = try resources.prepareSession(JSONEncoder().encode(request), clientUID: geteuid(), sessions: sessions)
            XCTAssertEqual(record.phase, .prepared)
            XCTAssertNotEqual(record.sessionID, request.requestID)
            XCTAssertEqual(record.credentialRevision, request.credentialRevision)
            XCTAssertEqual(record.settingsRevision, 29)
            let journal = try Data(contentsOf: root.appendingPathComponent(PreparedSessionStore.journalName))
            XCTAssertEqual(try PreparedSessionRecord.decode(journal), record)
            XCTAssertFalse(String(decoding: journal, as: UTF8.self).contains("private-key"))
            try sessions.withVerifiedWorkspace(sessionID: record.sessionID, clientUID: geteuid()) { directory in
                try directory.requirePrivate()
                for asset in ApprovedResourceCatalog.native {
                    var source = stat(), copy = stat()
                    XCTAssertEqual(stat(root.appendingPathComponent("resources/" + asset.filename).path, &source), 0)
                    XCTAssertEqual(fstatat(directory.descriptor, PreparedSessionStore.filename(asset), &copy, AT_SYMLINK_NOFOLLOW), 0)
                    XCTAssertNotEqual(source.st_ino, copy.st_ino)
                    XCTAssertEqual(copy.st_nlink, 1)
                    XCTAssertEqual(copy.st_mode & 0o777, asset.mode)
                }
                let config = try XCTUnwrap(directory.read("config.json", limit: ServiceMessages.maximumConfigurationBytes))
                let value = try JSONSerialization.jsonObject(with: config) as! [String: Any]
                let socket = value["external-controller-unix"] as! String
                XCTAssertEqual(socket, directory.path + "/c.sock")
                XCTAssertLessThan(socket.utf8.count, 104)
            }
            // Replacing a shared resource cannot alter an immutable session copy.
            let source = root.appendingPathComponent("resources/" + ApprovedResourceCatalog.native[0].filename)
            XCTAssertEqual(chmod(source.path, 0o600), 0)
            try Data("changed cache".utf8).write(to: source)
            XCTAssertNoThrow(try sessions.withVerifiedWorkspace(sessionID: record.sessionID, clientUID: geteuid()) { _ in () })
            XCTAssertThrowsError(try sessions.discard(sessionID: record.sessionID, clientUID: geteuid() + 1))
            XCTAssertThrowsError(try sessions.withVerifiedWorkspace(sessionID: record.sessionID, clientUID: 0) { _ in () })
            let copiedCore = root.appendingPathComponent("sessions/\(record.sessionID.uuidString)/mihomo")
            XCTAssertEqual(chmod(copiedCore.path, 0o400), 0)
            XCTAssertThrowsError(try sessions.withVerifiedWorkspace(sessionID: record.sessionID, clientUID: geteuid()) { _ in () })
            XCTAssertEqual(chmod(copiedCore.path, 0o500), 0)
            let config = root.appendingPathComponent("sessions/\(record.sessionID.uuidString)/config.json")
            try Data("corrupted private configuration".utf8).write(to: config)
            XCTAssertThrowsError(try sessions.withVerifiedWorkspace(sessionID: record.sessionID, clientUID: geteuid()) { _ in () })
            try sessions.discard(sessionID: record.sessionID, clientUID: geteuid())
            XCTAssertNil(try sessions.current())
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path), [])
        }
    }

    func testPartialPreparationRetainsJournalAndRestartCanRecoverIdempotently() throws {
        try fixture { root in
            var store: PreparedSessionStore? = try PreparedSessionStore(path: root.path, owner: geteuid())
            let record = try leavePartial(store!)
            let bytes = try Data(contentsOf: root.appendingPathComponent(PreparedSessionStore.journalName))
            XCTAssertThrowsError(try store!.prepare(request(), clientUID: geteuid()) { _ in XCTFail("Must not overwrite a live baseline") })
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(PreparedSessionStore.journalName)), bytes)
            store = nil
            let restarted = try PreparedSessionStore(path: root.path, owner: geteuid())
            XCTAssertEqual(try restarted.current(), record)
            try restarted.recoverPreparation()
            try restarted.recoverPreparation()
            XCTAssertNil(try restarted.current())
        }
    }

    func testMissingResourcesLeaveRecoverablePreparationAndRejectRootClient() throws {
        try fixture { root in
            let resources = try ServiceResourceStore(path: root.appendingPathComponent("resources").path, owner: geteuid())
            let sessions = try PreparedSessionStore(path: root.path, owner: geteuid())
            let bytes = try JSONEncoder().encode(request())
            XCTAssertThrowsError(try resources.prepareSession(bytes, clientUID: 0, sessions: sessions))
            XCTAssertNil(try sessions.current())
            XCTAssertThrowsError(try resources.prepareSession(bytes, clientUID: geteuid(), sessions: sessions))
            XCTAssertEqual(try sessions.current()?.phase, .preparing)
            try sessions.recoverPreparation()
            XCTAssertNil(try sessions.current())
        }
    }

    func testUnknownSchemaPhaseAndFieldsNeverAuthorizeDeletion() throws {
        try fixture { root in
            let sessions = try PreparedSessionStore(path: root.path, owner: geteuid())
            _ = try leavePartial(sessions)
            let path = root.appendingPathComponent(PreparedSessionStore.journalName)
            let original = try Data(contentsOf: path)
            let fields = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            for (key, value) in [("schema", 2 as Any), ("phase", "running" as Any), ("pid", 12345 as Any),
                                 ("sessionID", "../outside" as Any), ("clientUID", 0 as Any)] {
                var invalid = fields; invalid[key] = value
                let bytes = try JSONSerialization.data(withJSONObject: invalid)
                try bytes.write(to: path)
                XCTAssertThrowsError(try sessions.recoverPreparation())
                XCTAssertEqual(try Data(contentsOf: path), bytes)
            }
            try original.write(to: path)
            try sessions.recoverPreparation()
        }
    }

    func testCleanupRejectsUnknownFilesLinksAndDirectoriesBeforeDeletingKnownFiles() throws {
        for kind in ["unknown", "symlink", "hardlink", "directory"] {
            try fixture { root in
                let sessions = try PreparedSessionStore(path: root.path, owner: geteuid())
                let record = try leavePartial(sessions)
                let directory = root.appendingPathComponent("sessions/" + record.sessionID.uuidString)
                let known = directory.appendingPathComponent("country.mmdb")
                let unexpected = directory.appendingPathComponent(kind == "unknown" ? "foreign" : "GeoSite.dat")
                switch kind {
                case "symlink": try FileManager.default.createSymbolicLink(at: unexpected, withDestinationURL: known)
                case "hardlink": try FileManager.default.linkItem(at: known, to: unexpected)
                case "directory": try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: false)
                default: try Data("unrecognized".utf8).write(to: unexpected)
                }
                XCTAssertThrowsError(try sessions.recoverPreparation())
                XCTAssertTrue(FileManager.default.fileExists(atPath: known.path))
                XCTAssertNotNil(try sessions.current())
                try FileManager.default.removeItem(at: unexpected)
                try sessions.recoverPreparation()
            }
        }
    }

    func testJournalBeforeDirectoryAndInterruptedCleanupAreRecoverable() throws {
        try fixture { root in
            let sessions = try PreparedSessionStore(path: root.path, owner: geteuid())
            let record = PreparedSessionRecord(request: try request(), clientUID: geteuid())
            let directory = try SecureDirectory(path: root.path, owner: geteuid())
            try directory.write(PreparedSessionStore.journalName, data: JSONEncoder().encode(record), mode: 0o600)
            try sessions.recoverPreparation() // Crash after journal, before mkdir.
            XCTAssertNil(try sessions.current())
            let partial = try leavePartial(sessions)
            let child = root.appendingPathComponent("sessions/" + partial.sessionID.uuidString)
            try FileManager.default.removeItem(at: child.appendingPathComponent("country.mmdb"))
            try sessions.recoverPreparation() // Crash after unlink, before rmdir.
            XCTAssertNil(try sessions.current())
        }
    }

    func testOrphanDirectoriesLocksAndLongPathsFailClosed() throws {
        try fixture { root in
            let sessions = try PreparedSessionStore(path: root.path, owner: geteuid())
            XCTAssertThrowsError(try PreparedSessionStore(path: root.path, owner: geteuid()))
            let orphan = root.appendingPathComponent("sessions/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            XCTAssertThrowsError(try sessions.recoverPreparation())
            XCTAssertThrowsError(try sessions.prepare(request(), clientUID: geteuid()) { _ in XCTFail("Unexpected resource write") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
            let long = root.appendingPathComponent(String(repeating: "a", count: 70))
            try FileManager.default.createDirectory(at: long, withIntermediateDirectories: false)
            let other = try PreparedSessionStore(path: long.path, owner: geteuid())
            XCTAssertThrowsError(try other.prepare(request(), clientUID: geteuid()) { _ in XCTFail("Unexpected resource write") })
            XCTAssertNil(try other.current())
        }
    }

    func testPrivateDirectoriesRejectReadACLsAndInsecureExistingPermissions() throws {
        try fixture { root in
            let directory = try SecureDirectory(path: root.path, owner: geteuid())
            let child = try XCTUnwrap(directory.privateChild("sessions", create: true))
            func chmod(_ args: [String]) throws {
                let command = try OwnedChildProcess(executable: "/bin/chmod", arguments: args + [child.path], directory: root.path)
                XCTAssertEqual(try command.runToExit(timeout: 3), .exited(0))
            }
            try chmod(["+a", "everyone allow read,search"])
            XCTAssertThrowsError(try child.requirePrivate())
            XCTAssertThrowsError(try PreparedSessionStore(path: root.path, owner: geteuid()))
            try chmod(["-N"])
            try chmod(["755"])
            XCTAssertThrowsError(try directory.privateChild("sessions"))
            try chmod(["700"])
            try child.write("secret", data: Data("private".utf8), mode: 0o644)
            XCTAssertThrowsError(try child.requirePrivateFile("secret"))
            XCTAssertEqual(try directory.entries(), ["network.lock", "sessions"])
            XCTAssertEqual(try directory.entries(), ["network.lock", "sessions"])
        }
    }
}
