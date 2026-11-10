import Darwin
import Foundation
import XCTest
@testable import FreeV6Desktop
import FreeV6System

final class DesktopLogsTests: XCTestCase {
    private func freshDirectory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/log-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    @MainActor func testPausedAndFilteredExportStaysStableAsOtherEventsArrive() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = DesktopLogs(directory: directory)
        logs.record(.opened)
        logs.record(.serviceMissing)
        logs.level = .warning
        logs.togglePause()
        logs.record(.noticeMissing)
        XCTAssertEqual(logs.visible.map(\.event), [.serviceMissing])
        let file = DesktopLogs.text(logs.visible)
        XCTAssertTrue(file.contains("需要安装网络服务"))
        XCTAssertFalse(file.contains("维护者公告"))
        logs.togglePause()
        XCTAssertEqual(logs.visible.map(\.event), [.serviceMissing, .noticeMissing])
        logs.level = .error
        XCTAssertTrue(logs.visible.isEmpty)
        await logs.finishWrites()
        XCTAssertFalse(logs.storageUnavailable)
        let nextLaunch = DesktopLogs(directory: directory)
        nextLaunch.record(.connected)
        await nextLaunch.finishWrites()
        XCTAssertEqual(nextLaunch.records.map(\.event), [.opened, .serviceMissing, .noticeMissing, .connected])
    }

    func testStorageBoundsArePerSourceAndReplayedBatchesAreIdempotent() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = UserEventJournal(root: directory)
        let app = UserEvent(.opened)
        let events = (0..<(UserEventJournal.perSourceLimit + 15)).map { UserEvent(.operationFailed, at: Date(timeIntervalSince1970: Double($0))) }
        try journal.append([app] + events)
        try journal.append(events)
        let history = try journal.history()
        XCTAssertTrue(history.contains(app))
        XCTAssertEqual(history.filter { $0.event.source == .service }, Array(events.suffix(UserEventJournal.perSourceLimit)))
        var info = stat()
        XCTAssertEqual(stat(directory.appendingPathComponent("journal-v1/service.events.json").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    @MainActor func testCorruptOrLinkedHistoryCannotSupplyTextToAnExport() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try UserEventJournal(root: directory).history()
        let candidate = directory.appendingPathComponent("journal-v1/app.events.json")
        let secret = "https://user:secret@example.invalid/private"
        let other = directory.appendingPathComponent("other")
        try Data(secret.utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: other)
        let logs = DesktopLogs(directory: directory)
        logs.record(.opened)
        await logs.finishWrites()
        XCTAssertTrue(logs.storageUnavailable)
        let report = DesktopDiagnosticSnapshot(version: secret, service: .needsRepair, network: .unknown,
                                              coreReady: nil, geodataReady: false, settingsLoaded: false).text(events: logs.records)
        XCTAssertFalse(report.contains(secret))
        XCTAssertTrue(report.contains("应用版本  未知"))
        XCTAssertTrue(report.contains("应用已启动"))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), secret)
        try FileManager.default.removeItem(at: candidate)
        let injected = try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "date": 0, "event": secret]])
        try injected.write(to: candidate)
        XCTAssertThrowsError(try UserEventJournal(root: directory).history())
    }

    @MainActor func testClearDuringInitialReadDropsPausedFilteredAndPendingHistoryButKeepsNewEvents() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = UserEventJournal(root: directory)
        try journal.append([UserEvent(.settingsReady)])
        let logs = DesktopLogs(directory: directory)
        logs.record(.opened)
        logs.record(.serviceMissing)
        logs.level = .warning
        logs.togglePause()
        // These calls run in one main-actor turn before the initial read/drain can finish.
        logs.clear()
        logs.record(.noticeMissing)
        await logs.finishWrites()
        XCTAssertNil(logs.clearError)
        XCTAssertTrue(logs.didClear)
        XCTAssertTrue(logs.visible.isEmpty)
        XCTAssertNotNil(logs.paused)
        XCTAssertEqual(logs.records.map(\.event), [.noticeMissing])
        logs.togglePause()
        XCTAssertEqual(logs.level, .warning)
        XCTAssertEqual(logs.visible.map(\.event), [.noticeMissing])
        let nextLaunch = DesktopLogs(directory: directory)
        await nextLaunch.finishWrites()
        XCTAssertEqual(nextLaunch.records.map(\.id), logs.records.map(\.id))
    }

    func testClearRejectsDelayedReplayAndPreservesConcurrentAndUnrelatedFiles() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = UserEventJournal(root: directory)
        let other = UserEventJournal(root: directory)
        let cutoff = Date()
        let old = UserEvent(.opened, at: cutoff.addingTimeInterval(-2))
        let newer = UserEvent(.connected, at: cutoff.addingTimeInterval(2))
        try other.append([old, newer])
        let exported = directory.appendingPathComponent("journal-v1/my-export.txt")
        try Data("keep".utf8).write(to: exported)
        XCTAssertEqual(try journal.clear(through: cutoff), [newer])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal-v1/app.events.json").path))
        try other.append([old, newer])
        XCTAssertEqual(try journal.history(), [newer])
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "keep")
    }

    @MainActor func testFailedClearProtectsLinksAndCanBeRetried() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = DesktopLogs(directory: directory)
        logs.record(.opened)
        await logs.finishWrites()
        let target = directory.appendingPathComponent("service-private.txt")
        try Data("safe".utf8).write(to: target)
        let link = directory.appendingPathComponent("journal-v1/service.events.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        logs.clear()
        await logs.finishWrites()
        XCTAssertNotNil(logs.clearError)
        XCTAssertFalse(logs.didClear)
        XCTAssertEqual(logs.records.map(\.event), [.opened])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal-v1/app.events.json").path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "safe")
        try FileManager.default.removeItem(at: link)
        logs.clear()
        await logs.finishWrites()
        XCTAssertNil(logs.clearError)
        XCTAssertTrue(logs.records.isEmpty)
        XCTAssertTrue(try UserEventJournal(root: directory).history().isEmpty)
    }

    func testLogCommandsFollowFocusWhileDiagnosticsRemainAvailableDuringRecovery() {
        var state = DesktopCommandState()
        state.network = .disconnecting
        XCTAssertTrue(state.availability(.exportDiagnostics).enabled)
        XCTAssertFalse(state.availability(.exportLogs, in: .main(.logs)).enabled)
        state.hasVisibleLogs = true
        XCTAssertTrue(state.availability(.exportLogs, in: .main(.logs)).enabled)
        XCTAssertFalse(state.availability(.exportLogs, in: .preferences(.general)).enabled)
        XCTAssertFalse(state.availability(.exportLogs, in: .main(.nodes)).enabled)
        state.promptActive = true
        XCTAssertFalse(state.availability(.exportDiagnostics).enabled)
    }
}
