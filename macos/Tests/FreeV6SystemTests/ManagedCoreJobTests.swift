import Darwin
import Foundation
import XCTest
@testable import FreeV6System

final class ManagedCoreJobTests: XCTestCase {
    func testListDistinguishesAbsentRunningExitedAndSignaledWithoutDiagnosticParsing() throws {
        let label = "dev.freev6.core." + UUID().uuidString.lowercased()
        func parse(_ rows: String) throws -> CoreJobStatus? {
            try ManagedCoreJob.parseList(Data(("PID\tStatus\tLabel\n" + rows).utf8), label: label)
        }
        XCTAssertNil(try parse("3\t0\tother job with spaces\n-\t37\tother.job\n"))
        XCTAssertEqual(try parse("123\t0\t\(label)\n"), CoreJobStatus(pid: 123, lastExit: 0))
        XCTAssertEqual(try parse("-\t37\t\(label)\n"), CoreJobStatus(pid: nil, lastExit: 37))
        XCTAssertEqual(try parse("-\t-9\t\(label)\n"), CoreJobStatus(pid: nil, lastExit: -9))
        for rows in ["-\t0\t\(label)\n-\t0\t\(label)\n", "1\t0\t\(label)\n",
                     "0\t0\t\(label)\n", "-1\t0\t\(label)\n", "12\t999999\t\(label)\n",
                     "12\t0\t\(label)", "12\tunknown\t\(label)\n", "malformed\n"] {
            XCTAssertThrowsError(try parse(rows))
        }
        for bytes in [Data(), Data([0xff, 0x0a]), Data("unexpected header\n".utf8), Data(repeating: 1, count: 1_048_577)] {
            XCTAssertThrowsError(try ManagedCoreJob.parseList(bytes, label: label))
        }
    }

    func testCoreDefinitionCannotAutoStartOrLeakOutputAndUsesPrivateSessionPaths() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sessionID = UUID()
        let root = repository.appendingPathComponent("build/core-job-tests/" + sessionID.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SecureDirectory(path: root.path, owner: geteuid())
        let job = ManagedCoreJob(sessionID: sessionID)
        let value = try PropertyListSerialization.propertyList(from: job.definition(directory: directory, checkOnly: true), format: nil) as! [String: Any]
        XCTAssertEqual(value["Label"] as? String, job.label)
        XCTAssertEqual(value["ProgramArguments"] as? [String], ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C",
            root.path + "/mihomo", "-t", "-d", root.path, "-f", root.path + "/config.json"])
        XCTAssertEqual(value["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(value["KeepAlive"] as? Bool, false)
        XCTAssertEqual(value["AbandonProcessGroup"] as? Bool, false)
        XCTAssertEqual(value["Umask"] as? Int, 0o077)
        for key in ["StandardInPath", "StandardOutPath", "StandardErrorPath"] { XCTAssertEqual(value[key] as? String, "/dev/null") }
        XCTAssertNil(value["MachServices"])
        XCTAssertNil(value["WatchPaths"])
        XCTAssertThrowsError(try ManagedCoreJob(sessionID: UUID()).definition(directory: directory, checkOnly: true))
        if geteuid() != 0 { XCTAssertThrowsError(try job.status()) }
    }

    func testOnlyLaunchdServiceCanUseInheritedGroupAndOldGroupQueriesDoNotSignal() throws {
        XCTAssertThrowsError(try ServiceProcessOrigin.current())
        XCTAssertThrowsError(try OwnedChildProcess(executable: "/usr/bin/true", arguments: [], directory: "/", group: .inheritService))
        let bootID = try ServiceProcessOrigin.bootIdentity()
        XCTAssertEqual(try ServiceProcessOrigin.bootIdentity(), bootID)
        let current = ServiceProcessOrigin(bootID: bootID, groupID: getpgrp(), ownerUID: geteuid())
        XCTAssertFalse(try current.groupHasExited())
        XCTAssertTrue(try ServiceProcessOrigin(bootID: UUID(), groupID: getpgrp(), ownerUID: geteuid()).groupHasExited())
        XCTAssertThrowsError(try ServiceProcessOrigin(bootID: bootID, groupID: 1, ownerUID: geteuid()).groupHasExited())
        XCTAssertThrowsError(try ServiceProcessOrigin(bootID: bootID, groupID: getpgrp(), ownerUID: geteuid() + 1).groupHasExited())
    }
}
