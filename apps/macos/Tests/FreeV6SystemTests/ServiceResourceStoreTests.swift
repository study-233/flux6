import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import FreeV6System

final class ServiceResourceStoreTests: XCTestCase {
    private func fixture(_ body: (URL, ServiceResourceStore) throws -> Void) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("build/resource-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, ServiceResourceStore(path: root.appendingPathComponent("resources").path, owner: geteuid()))
    }
    private func source(_ root: URL, data: Data) throws -> FileHandle {
        let path = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: path)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        return try FileHandle(forReadingFrom: path)
    }
    private func rejects(_ expected: ResourceStoreError, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }

    func testRequestsRejectPathsHashesUnknownVersionsAndWrongArchitecture() throws {
        let id = ApprovedResourceCatalog.native[0].id
        let request = ResourceRequest(resourceID: id)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try ServiceMessages.decodeResource(data, installing: true).resourceID, id)
        var fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in [("path", "/tmp/core"), ("sha256", String(repeating: "a", count: 64)), ("uid", "0")] {
            var bad = fields; bad[key] = value
            XCTAssertThrowsError(try ServiceMessages.decodeResource(JSONSerialization.data(withJSONObject: bad), installing: true))
        }
        fields["protocolVersion"] = 1
        XCTAssertThrowsError(try ServiceMessages.decodeResource(JSONSerialization.data(withJSONObject: fields), installing: true))
        for id in ["../../core", "mihomo-darwin-arm64-unapproved"] + ApprovedResourceCatalog.pinned.filter({
            $0.architecture != nil && $0.architecture != ApprovedResourceCatalog.nativeArchitecture
        }).map(\.id) {
            rejects(.unapproved) { _ = try ServiceMessages.decodeResource(JSONEncoder().encode(ResourceRequest(resourceID: id)), installing: true) }
        }
        XCTAssertThrowsError(try ServiceMessages.decodeResource(Data(repeating: 32, count: 4097), installing: false))
        XCTAssertThrowsError(try ServiceMessages.decodeResource(data, installing: false))
    }

    func testRejectsForeignOwnerRootClientPipesHardLinksAndOversizedFiles() throws {
        try fixture { root, store in
            let id = ApprovedResourceCatalog.native[0].id
            let handle = try source(root, data: Data("untrusted".utf8))
            defer { try? handle.close() }
            rejects(.invalidSource) { _ = try store.install(id: id, source: handle, clientUID: geteuid() + 1) }
            rejects(.invalidSource) { _ = try store.install(id: id, source: handle, clientUID: 0) }
            let pipe = Pipe()
            rejects(.invalidSource) { _ = try store.install(id: id, source: pipe.fileHandleForReading, clientUID: geteuid()) }
            XCTAssertEqual(fchmod(handle.fileDescriptor, 0o622), 0)
            rejects(.invalidSource) { _ = try store.install(id: id, source: handle, clientUID: geteuid()) }
            XCTAssertEqual(fchmod(handle.fileDescriptor, 0o600), 0)
            let oversized = root.appendingPathComponent("oversized")
            let fd = open(oversized.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let large = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            XCTAssertEqual(ftruncate(fd, off_t(ApprovedResourceCatalog.maximumBytes + 1)), 0)
            rejects(.tooLarge) { _ = try store.install(id: id, source: large, clientUID: geteuid()) }
            try FileManager.default.linkItem(at: oversized, to: root.appendingPathComponent("alias"))
            rejects(.invalidSource) { _ = try store.install(id: id, source: large, clientUID: geteuid()) }
            XCTAssertTrue(try store.status().allSatisfy { !$0.available })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("resources").path), ["resources.lock"])
        }
    }

    func testGzipRejectsTruncationTrailingMembersCRCAndExpansionLimit() throws {
        let small = Data(base64Encoded: "H4sIAAAAAAAA/0tMRAUA1WjWzxAAAAA=")!
        let large = Data(base64Encoded: "H4sIAAAAAAAA/+3BMQEAAADCoKzrX8LDGkABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA3AAwUZfKAAACAA==")!
        try fixture { root, _ in
            func inflate(_ data: Data, limit: Int) throws -> Data {
                let input = try source(root, data: data)
                defer { try? input.close() }
                let dir = try SecureDirectory(path: root.appendingPathComponent("resources").path, owner: geteuid())
                return try dir.withTemporaryFile { output, _ in
                    try ResourceIO.inflateGzip(input.fileDescriptor, into: output, limit: limit, deadline: ResourceIO.deadline())
                    var bytes = [UInt8](repeating: 0, count: limit + 1)
                    let count = try ResourceIO.read(output, buffer: &bytes, offset: 0, count: bytes.count)
                    return Data(bytes.prefix(count))
                }
            }
            XCTAssertEqual(try inflate(small, limit: 16), Data(repeating: 97, count: 16))
            XCTAssertEqual(try inflate(large, limit: 131072), Data(repeating: 97, count: 131072))
            rejects(.tooLarge) { _ = try inflate(large, limit: 131071) }
            for data in [small.dropLast(), small + small, small + Data([0]), Data("not gzip".utf8)] {
                rejects(.invalidArchive) { _ = try inflate(Data(data), limit: 1024) }
            }
            var corrupt = small; corrupt[corrupt.count - 8] ^= 1
            rejects(.invalidArchive) { _ = try inflate(corrupt, limit: 1024) }
        }
    }

    func testOfficialAssetsAreCopiedRecheckedAndSurviveFailedReplacement() throws {
        guard let runtime = ProcessInfo.processInfo.environment["FREEV6_RUNTIME_FIXTURES_DIR"],
              let geodata = ProcessInfo.processInfo.environment["FREEV6_GEODATA_FIXTURES_DIR"] else {
            throw XCTSkip("Set official runtime and geodata fixture directories")
        }
        try fixture { root, store in
            XCTAssertTrue(try store.status().allSatisfy { !$0.available })
            for asset in ApprovedResourceCatalog.native {
                let sourcePath: URL
                if let arch = asset.architecture {
                    let filename = arch == "arm64" ? "mihomo-darwin-arm64-v1.19.31.gz" : "mihomo-darwin-amd64-v1-v1.19.31.gz"
                    sourcePath = URL(fileURLWithPath: runtime).appendingPathComponent(filename)
                } else { sourcePath = URL(fileURLWithPath: geodata).appendingPathComponent(String(asset.id.split(separator: "/").last!)) }
                let file = try FileHandle(forReadingFrom: sourcePath)
                defer { try? file.close() }
                try file.seek(toOffset: 3) // Shared descriptor offsets never affect the copy.
                XCTAssertTrue(try store.install(id: asset.id, source: file, clientUID: geteuid()).available)
                XCTAssertEqual(try file.offset(), 3)
                let installed = root.appendingPathComponent("resources/" + asset.filename)
                let old = try Data(contentsOf: installed)
                XCTAssertEqual(SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined(), asset.sha256)
                var info = stat()
                XCTAssertEqual(lstat(installed.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, asset.mode)
                XCTAssertEqual(info.st_uid, geteuid())
                let invalid = try source(root, data: Data("invalid replacement".utf8))
                defer { try? invalid.close() }
                rejects(.integrity) { _ = try store.install(id: asset.id, source: invalid, clientUID: geteuid()) }
                XCTAssertEqual(try Data(contentsOf: installed), old)
                XCTAssertEqual(chmod(installed.path, 0o600), 0)
                try Data("corrupt cache".utf8).write(to: installed)
                XCTAssertFalse(try store.status().first { $0.id == asset.id }!.available)
                _ = try store.install(id: asset.id, source: file, clientUID: geteuid())
            }
            XCTAssertTrue(try store.status().allSatisfy(\.available))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("resources").path).contains { $0.hasPrefix(".staging-") })
        }
    }

    func testSecurePublicationDoesNotFollowSymlinksOrReplaceHardLinks() throws {
        try fixture { root, _ in
            let directory = try SecureDirectory(path: root.appendingPathComponent("resources").path, owner: geteuid())
            let original = root.appendingPathComponent("original")
            try Data("preserved".utf8).write(to: original)
            let target = root.appendingPathComponent("resources/target")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            XCTAssertThrowsError(try directory.publish("target", mode: 0o400) { _ in XCTFail("must reject before preparing") })
            try FileManager.default.removeItem(at: target)
            try FileManager.default.linkItem(at: original, to: target)
            XCTAssertThrowsError(try directory.publish("target", mode: 0o400) { _ in XCTFail("must reject before preparing") })
            XCTAssertEqual(try Data(contentsOf: original), Data("preserved".utf8))
            try FileManager.default.removeItem(at: target)
            XCTAssertThrowsError(try directory.publish("target", mode: 0o400) { _ in throw ResourceStoreError.integrity })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("resources").path), ["resources.lock"])
        }
    }

    func testWriterLeaseAndInterruptedTransferCleanup() throws {
        try fixture { root, _ in
            let path = root.appendingPathComponent("restart").path
            var first: ServiceResourceStore? = try ServiceResourceStore(path: path, owner: geteuid())
            XCTAssertNotNil(first)
            let stale = URL(fileURLWithPath: path).appendingPathComponent(".staging-" + UUID().uuidString)
            try Data("interrupted private copy".utf8).write(to: stale)
            XCTAssertEqual(chmod(stale.path, 0o600), 0)
            rejects(.busy) { _ = try ServiceResourceStore(path: path, owner: geteuid()) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
            first = nil
            let restarted = try ServiceResourceStore(path: path, owner: geteuid())
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertTrue(try restarted.status().allSatisfy { !$0.available })
        }
    }

    func testRejectsWrongMachOAndEnforcesDeadline() throws {
        try fixture { root, _ in
            var header = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0])
            header.append(Data(repeating: 0, count: 16))
            let file = try source(root, data: header)
            defer { try? file.close() }
            try ResourceIO.verifyMachO(file.fileDescriptor, architecture: "arm64")
            rejects(.integrity) { try ResourceIO.verifyMachO(file.fileDescriptor, architecture: "amd64") }
            rejects(.timedOut) {
                try ResourceIO.scan(file.fileDescriptor, limit: 32, expected: "", deadline: 0)
            }
        }
    }

    func testACLWriteGrantsCannotBypassPrivatePOSIXPermissions() throws {
        try fixture { root, _ in
            let path = root.appendingPathComponent("resources")
            let directory = try SecureDirectory(path: path.path, owner: geteuid())
            try directory.write("acl-test", data: Data("private".utf8), mode: 0o600)
            let file = path.appendingPathComponent("acl-test")
            func acl(_ arguments: [String], _ target: URL) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                process.arguments = arguments + [target.path]
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
            defer { try? acl(["-N"], file); try? acl(["-N"], path) }
            try acl(["+a", "everyone allow write"], file)
            XCTAssertThrowsError(try directory.read("acl-test", limit: 128))
            try acl(["-N"], file)
            try acl(["+a", "everyone deny delete"], file)
            XCTAssertEqual(try directory.read("acl-test", limit: 128), Data("private".utf8))
            try acl(["+a", "everyone allow add_file"], path)
            XCTAssertThrowsError(try SecureDirectory(path: path.path, owner: geteuid()))
        }
    }
}
