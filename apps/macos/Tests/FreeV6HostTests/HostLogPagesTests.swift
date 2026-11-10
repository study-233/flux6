import XCTest
import FreeV6Desktop
import FreeV6System
@testable import FreeV6Host

@MainActor final class HostLogPagesTests: XCTestCase {
    private func rows(_ response: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(response["rows"] as? [[String: Any]])
    }

    func testOlderPagesDoNotOverlapAndABurstIsDeliveredWithoutMissingRows() throws {
        let logs = DesktopLogs(directory: nil), pager = HostLogPages(logs)
        for _ in 0..<70 { logs.record(.opened) }
        let epoch = try XCTUnwrap(pager.metadata()["epoch"] as? String)
        let recent = try rows(pager.read(["epoch": epoch]))
        XCTAssertEqual(recent.count, 32)
        XCTAssertEqual(recent.compactMap { $0["cursor"] as? Int }, Array((39...70).reversed()))
        let prior = try rows(pager.read(["epoch": epoch, "before": 39]))
        XCTAssertEqual(prior.compactMap { $0["cursor"] as? Int }, Array((7...38).reversed()))
        let first = try rows(pager.read(["epoch": epoch, "before": 7]))
        XCTAssertEqual(first.compactMap { $0["cursor"] as? Int }, Array((1...6).reversed()))
        let ids = (recent + prior + first).compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(ids).count,70)

        for _ in 0..<38 { logs.record(.profileFailure) }
        let delta = try rows(pager.read(["epoch": epoch, "after": 70]))
        XCTAssertEqual(delta.compactMap { $0["cursor"] as? Int }, Array((71...102).reversed()))
        let rest = try rows(pager.read(["epoch": epoch, "after": 102]))
        XCTAssertEqual(rest.compactMap { $0["cursor"] as? Int }, Array((103...108).reversed()))
        XCTAssertEqual(pager.metadata()["epoch"] as? String,epoch)

        for _ in 0..<128 { logs.record(.opened) }
        let view = pager.metadata()
        XCTAssertEqual(view["epoch"] as? String,epoch)
        let floors = try XCTUnwrap(view["floors"] as? [String:Int])
        XCTAssertEqual(floors[EventSource.worker.title],71)
        XCTAssertEqual(floors[EventSource.app.title],109)
        XCTAssertEqual(view["count"] as? Int,166)
    }

    func testFilterPauseClearInvalidateOutstandingPagesAndExportAllMatchingRows() async throws {
        let logs = DesktopLogs(directory: nil), pager = HostLogPages(logs)
        for _ in 0..<52 { logs.record(.settingsFailure) }
        logs.record(.opened)
        let initial = try XCTUnwrap(pager.metadata()["epoch"] as? String)
        logs.level = .error
        let filtered = try XCTUnwrap(pager.metadata()["epoch"] as? String)
        XCTAssertNotEqual(filtered, initial)
        XCTAssertEqual(try pager.read(["epoch":initial,"before":15])["reset"] as? Bool,true)
        logs.togglePause()
        let paused = try XCTUnwrap(pager.metadata()["epoch"] as? String)
        XCTAssertNotEqual(filtered,paused)
        logs.record(.controlFailure)
        let exported = try XCTUnwrap(pager.export(["epoch":paused])["text"] as? String)
        XCTAssertEqual(exported.components(separatedBy:"配置读写未完成").count - 1,52)
        XCTAssertFalse(exported.contains("读取或更改核心状态失败"))
        XCTAssertFalse(exported.contains("应用已启动"))
        XCTAssertThrowsError(try pager.export(["epoch":initial]))

        logs.clear(); await logs.finishWrites()
        let cutoff = try XCTUnwrap(pager.metadata()["epoch"] as? String)
        XCTAssertNotEqual(cutoff,paused)
        XCTAssertEqual(try pager.read(["epoch":paused,"after":1])["reset"] as? Bool,true)
        XCTAssertTrue(try rows(pager.read(["epoch":paused,"before":32])).isEmpty)
        logs.record(.profileFailure)
        XCTAssertTrue(try rows(pager.read(["epoch":cutoff])).isEmpty)
        logs.togglePause()
        XCTAssertEqual(try rows(pager.read([:])).map { $0["message"] as? String }, [.some("代理配置操作未完成")])
    }
}
