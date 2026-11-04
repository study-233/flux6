import Darwin
import Foundation
import XCTest
import FreeV6Configuration
@testable import FreeV6System

final class OwnedChildProcessTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture(_ body: (String, URL) throws -> Void) throws {
        guard geteuid() != 0 else { throw XCTSkip("Process fixtures must run as an ordinary user") }
        guard let executable = ProcessInfo.processInfo.environment["FREEV6_PROCESS_TEST_BINARY"] else {
            throw XCTSkip("Build scripts/macos/build-process-fixture.sh and set FREEV6_PROCESS_TEST_BINARY")
        }
        let root = repository.appendingPathComponent("build/macos-process-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(executable, root)
    }
    private func assertReaped(_ child: OwnedChildProcess, file: StaticString = #filePath, line: UInt = #line) {
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child.pid, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }

    func testNormalExitSpawnFailureAndInvalidRequests() throws {
        try fixture { executable, root in
            let child = try OwnedChildProcess(executable: executable, arguments: ["exit"], directory: root.path)
            XCTAssertEqual(try child.runToExit(timeout: 3), .exited(37))
            XCTAssertEqual(try child.wait(timeout: 0), .exited(37))
            XCTAssertEqual(try child.stop(), ChildStop(exit: .exited(37), forced: false))
            assertReaped(child)
            for (path, arguments, directory) in [("relative", [], root.path), (executable, ["a\0b"], root.path),
                                                 (executable, [], "relative")] {
                XCTAssertThrowsError(try OwnedChildProcess(executable: path, arguments: arguments, directory: directory)) { error in
                    XCTAssertEqual(error as? ChildProcessError, .invalidRequest)
                }
            }
            for (path, directory) in [(root.appendingPathComponent("absent").path, root.path), (executable, root.appendingPathComponent("absent").path)] {
                XCTAssertThrowsError(try OwnedChildProcess(executable: path, arguments: ["exit"], directory: directory))
            }
            for timeout in [-1.0, .nan, .infinity, 3601] { XCTAssertThrowsError(try child.wait(timeout: timeout)) }
        }
    }

    func testChildIsolatesEnvironmentDescriptorsWorkingDirectorySignalsAndOutput() throws {
        try fixture { executable, root in
            let source = open("/dev/null", O_RDONLY)
            XCTAssertGreaterThanOrEqual(source, 0)
            defer { close(source) }
            let leaked = fcntl(source, F_DUPFD, 80)
            XCTAssertGreaterThanOrEqual(leaked, 80)
            defer { close(leaked) }
            XCTAssertEqual(fcntl(leaked, F_GETFD) & FD_CLOEXEC, 0)
            let marker = "FREEV6_CHILD_SECRET"
            let previous = getenv(marker).map { String(cString: $0) }
            XCTAssertEqual(setenv(marker, "test-only-sensitive-marker", 1), 0)
            defer {
                if let previous { setenv(marker, previous, 1) } else { unsetenv(marker) }
            }
            var mask = sigset_t(), original = sigset_t()
            sigemptyset(&mask); sigaddset(&mask, SIGTERM)
            XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &mask, &original), 0)
            defer { pthread_sigmask(SIG_SETMASK, &original, nil) }
            let child = try OwnedChildProcess(executable: executable, arguments: ["inspect", String(leaked), root.path], directory: root.path)
            XCTAssertEqual(try child.runToExit(timeout: 3), .exited(0))
            assertReaped(child)
        }
    }

    func testGracefulTerminationAndIndependentChildOwnership() throws {
        try fixture { executable, root in
            let child = try OwnedChildProcess(executable: executable, arguments: ["wait"], directory: root.path)
            let other = try OwnedChildProcess(executable: executable, arguments: ["wait"], directory: root.path)
            XCTAssertNil(try child.wait(timeout: 0.03))
            XCTAssertEqual(try child.stop(gracePeriod: 2), ChildStop(exit: .signaled(SIGTERM), forced: false))
            XCTAssertEqual(try child.stop(), ChildStop(exit: .signaled(SIGTERM), forced: false))
            assertReaped(child)
            XCTAssertNil(try other.wait(timeout: 0))
            XCTAssertEqual(try other.stop(gracePeriod: 2).exit, .signaled(SIGTERM))
            assertReaped(other)
        }
    }

    func testIgnoringTerminationEscalatesAndReaps() throws {
        try fixture { executable, root in
            let ready = root.appendingPathComponent("ready")
            let child = try OwnedChildProcess(executable: executable, arguments: ["ignore-term", ready.path], directory: root.path)
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !FileManager.default.fileExists(atPath: ready.path), DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
            XCTAssertEqual(try child.stop(gracePeriod: 0.05, killWait: 2), ChildStop(exit: .signaled(SIGKILL), forced: true))
            assertReaped(child)
        }
    }

    func testTimeoutIsReportedOnlyAfterReapingAndDeinitStopsChild() throws {
        try fixture { executable, root in
            let child = try OwnedChildProcess(executable: executable, arguments: ["wait"], directory: root.path)
            XCTAssertThrowsError(try child.runToExit(timeout: 0.02, gracePeriod: 1)) { error in
                XCTAssertEqual(error as? ChildProcessError, .timedOut)
            }
            assertReaped(child)
            var abandoned: OwnedChildProcess? = try OwnedChildProcess(executable: executable, arguments: ["wait"], directory: root.path)
            let pid = abandoned!.pid
            abandoned = nil
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
    }

    func testConcurrentStopAndWaitReturnSameExitWithoutAffectingAnotherChild() throws {
        try fixture { executable, root in
            let child = try OwnedChildProcess(executable: executable, arguments: ["wait"], directory: root.path)
            let other = try OwnedChildProcess(executable: executable, arguments: ["wait"], directory: root.path)
            let group = DispatchGroup(), lock = NSLock()
            var exits = [ChildExit](), failures = [Error]()
            for index in 0..<16 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    do {
                        let result = index % 2 == 0 ? try child.stop().exit : try XCTUnwrap(child.wait(timeout: 3))
                        lock.lock(); exits.append(result); lock.unlock()
                    } catch { lock.lock(); failures.append(error); lock.unlock() }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(failures.isEmpty)
            XCTAssertEqual(exits, Array(repeating: .signaled(SIGTERM), count: 16))
            assertReaped(child)
            XCTAssertNil(try other.wait(timeout: 0))
            _ = try other.stop()
        }
    }

    func testPinnedCoreParsesFullServiceConfigurationInOwnedChild() throws {
        guard let runtime = ProcessInfo.processInfo.environment["FREEV6_RUNTIME_FIXTURES_DIR"],
              let geodata = ProcessInfo.processInfo.environment["FREEV6_GEODATA_FIXTURES_DIR"] else {
            throw XCTSkip("Set official runtime and geodata fixture directories")
        }
        try fixture { _, root in
            let runtimeAsset = ApprovedResourceCatalog.native.first { $0.architecture != nil }!
            let filename = runtimeAsset.architecture == "arm64" ? "mihomo-darwin-arm64" : "mihomo-darwin-amd64-v1"
            let executable = URL(fileURLWithPath: runtime).appendingPathComponent(filename)
            let handle = try FileHandle(forReadingFrom: executable)
            defer { try? handle.close() }
            try ResourceIO.scan(handle.fileDescriptor, limit: runtimeAsset.limit, expected: runtimeAsset.sha256, deadline: ResourceIO.deadline())
            for asset in ApprovedResourceCatalog.native where asset.architecture == nil {
                let name = String(asset.id.split(separator: "/")[1])
                let data = try Data(contentsOf: URL(fileURLWithPath: geodata).appendingPathComponent(name))
                try data.write(to: root.appendingPathComponent(name))
            }
            let business = try JSONDecoder().decode(BusinessConfiguration.self,
                from: Data(contentsOf: repository.appendingPathComponent("shared/fixtures/warp-business-configuration.json")))
            let configuration = root.appendingPathComponent("config.json")
            try ServiceConfigurationAssembler.assemble(business, sessionID: UUID()).data.write(to: configuration)
            let child = try OwnedChildProcess(executable: executable.path,
                arguments: ["-t", "-d", root.path, "-f", configuration.path], directory: root.path)
            XCTAssertEqual(try child.runToExit(timeout: 20), .exited(0))
            assertReaped(child)
        }
    }

    func testLaunchdReadOnlyQueryUsesControlledProcess() throws {
        XCTAssertNoThrow(try LaunchdController().isLoaded())
    }
}
