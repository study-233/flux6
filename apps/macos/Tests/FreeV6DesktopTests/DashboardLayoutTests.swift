import CoreGraphics
import XCTest
@testable import FreeV6Desktop

final class DashboardLayoutTests: XCTestCase {
    func testOfflineModeWritesOnlyInKnownSafeSessionStates() {
        XCTAssertEqual(DashboardWorkingMode.source(phase: .idle, service: .ready, mayOwnSession: false), .savedDefault)
        XCTAssertEqual(DashboardWorkingMode.source(phase: .unknown, service: .missing, mayOwnSession: false), .savedDefault)
        XCTAssertEqual(DashboardWorkingMode.source(phase: .running, service: .ready, mayOwnSession: true), .liveSession)
        for phase: DesktopNetworkPhase in [.recovering, .occupied, .connecting, .disconnecting, .unknown] {
            XCTAssertNil(DashboardWorkingMode.source(phase: phase, service: .ready, mayOwnSession: true))
        }
        XCTAssertNil(DashboardWorkingMode.source(phase: .idle, service: .checking, mayOwnSession: false))
        XCTAssertNil(DashboardWorkingMode.source(phase: .unknown, service: .missing, mayOwnSession: true))
    }

    func testUsageHandlesEmptyOneDirectionAndTotalsBeyondUInt64() {
        let empty = DashboardTrafficUsage(upload: 0, download: 0)
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.downloadFraction, 0)
        XCTAssertEqual(DashboardTrafficUsage(upload: 1, download: 0).downloadFraction, 0)
        XCTAssertEqual(DashboardTrafficUsage(upload: 0, download: 1).downloadFraction, 1)
        let maximum = DashboardTrafficUsage(upload: .max, download: .max)
        XCTAssertEqual(maximum.total, Decimal(string: "36893488147419103230"))
        XCTAssertEqual(maximum.downloadFraction, 0.5)
    }

    func testDefaultControlsLeadAtBothWindowWidths() {
        let tiles = DashboardLayout().tiles
        XCTAssertEqual(tiles.map(\.kind), [.connection, .mode, .node, .usage, .speed])
        let spans = tiles.map { $0.size == .wide ? 2 : 1 }
        for width: CGFloat in [680, 880] {
            let frames = DashboardGridGeometry.frames(width: width, spans: spans) { index, _ in index < 3 ? 108 : 180 }
            XCTAssertEqual(frames.map(\.minY), width == 680 ? [0, 0, 120, 120, 312] : [0, 0, 0, 120, 120])
            XCTAssertEqual(frames.last!.maxX, width, accuracy: 0.001)
            if width == 680 { XCTAssertEqual(frames.last!.width, width, accuracy: 0.001) }
        }
    }

    func testPreviouslySavedLayoutStillSharesFirstRowAtBothWindowWidths() throws {
        let previous = Data(#"{"version":1,"tiles":[{"kind":"connection","size":"compact"},{"kind":"speed","size":"wide"},{"kind":"usage","size":"compact"},{"kind":"node","size":"compact"},{"kind":"mode","size":"compact"}]}"#.utf8)
        let saved = DashboardLayout(data: previous)
        XCTAssertEqual(saved.tiles.map(\.kind), [.connection, .speed, .usage, .node, .mode])
        XCTAssertEqual(DashboardLayout(data: try saved.encoded()), saved)
        let spans = [1, 2, 1, 1, 1]
        for width: CGFloat in [676, 876] {
            let frames = DashboardGridGeometry.frames(width: width, spans: spans) { index, _ in index == 1 ? 184 : 160 }
            XCTAssertEqual(frames.map(\.minY), width == 676 ? [0, 0, 196, 196, 368] : [0, 0, 196, 196, 196])
            XCTAssertEqual(frames[0].height, 184)
            XCTAssertEqual(frames[1].maxX, width, accuracy: 0.001)
            XCTAssertEqual(frames[1].minX - frames[0].maxX, 12, accuracy: 0.001)
        }
    }

    func testDraftCanBeDiscardedAndSavedOrderSurvivesRelaunch() throws {
        let saved = DashboardLayout()
        var draft = saved
        draft.move([.speed], before: .connection)
        draft.resize(.speed, to: .compact)
        draft.remove(.node)
        draft.add(.speed)
        XCTAssertEqual(saved.tiles.first?.kind, .connection)
        XCTAssertEqual(draft.tiles.map(\.kind), [.speed, .connection, .mode, .usage])
        XCTAssertEqual(DashboardLayout(data: try draft.encoded()), draft)
    }

    func testEmptyAndCorruptedLayoutsAreDistinct() throws {
        var empty = DashboardLayout()
        for kind in DashboardWidget.allCases { empty.remove(kind) }
        XCTAssertEqual(DashboardLayout(data: try empty.encoded()), empty)
        XCTAssertEqual(DashboardLayout(data: Data("bad".utf8)), DashboardLayout())
        let unrecognized = Data(#"{"version":1,"tiles":[{"kind":"unrecognized"}]}"#.utf8)
        XCTAssertEqual(DashboardLayout(data: unrecognized), DashboardLayout())
        let migrated = DashboardLayout(data: Data(#"{"version":1,"tiles":[{"kind":"future"},{"kind":"speed","size":"future"},{"kind":"speed"}]}"#.utf8))
        XCTAssertEqual(migrated.tiles, [DashboardTile(.speed)])
    }

    func testKeyboardAndDropAtEndAgreeAndKeepStableIdentity() {
        var keyboard = DashboardLayout()
        var drag = keyboard
        keyboard.step(.usage, by: 1)
        drag.move([.usage], before: nil)
        XCTAssertEqual(keyboard, drag)
        var handle = DashboardLayout()
        handle.move(.usage, onto: .speed)
        XCTAssertEqual(handle, drag)
        handle.move(.node, onto: .connection)
        XCTAssertEqual(handle.tiles.first?.kind, .node)
        let before = drag
        drag.move([.usage], before: .usage)
        drag.step(.usage, by: 1)
        XCTAssertEqual(before, drag)
    }
}
