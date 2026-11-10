import XCTest
@testable import FreeV6System
@testable import FreeV6Desktop

@MainActor final class DesktopNodeCatalogTests: XCTestCase {
    func testBuiltinNamesMatchTheGoGeneratedAccessGroup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/warp-business-configuration.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try XCTUnwrap(document["proxy-groups"] as? [[String: Any]])
        let group = try XCTUnwrap(groups.first { ($0["name"] as? String) == "♻️ 自动选择" })
        XCTAssertEqual(DesktopNodeGroup.warpNames, group["proxies"] as? [String])
    }

    func testOfflineChoiceSurvivesRestartAndRevalidatesAgainstCurrentSession() async throws {
        let suite = "FreeV6-OfflineNodes-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = SessionControlTarget(sessionID: UUID(), revision: 2)
        let token = UUID()
        let unsafe = "https://example.invalid/proxy?token=fixture-only"
        let members = ["东区", "西区", unsafe]
        let live = SessionNodeList(group: .access, selected: "东区", preferred: nil, automatic: true, members: members)
        let initial = DesktopCoreControls(defaults: defaults)
        initial.bind(target)
        await initial.inspect { SessionControlReply($0, state: SessionControlSnapshot(token: token, mode: .rule, groups: [live])) }
        initial.bind(nil)
        initial.saveNode(unsafe, in: .access)
        let relaunched = DesktopCoreControls(defaults: defaults)
        XCTAssertEqual(relaunched.previousGroups.first?.members, ["东区", "西区"])
        let local = relaunched.offlineGroup(.access, names: members, source: .configuration)
        XCTAssertNil(local.selected)
        XCTAssertEqual(local.chosen, unsafe)
        let saved = try PropertyListSerialization.data(fromPropertyList: defaults.persistentDomain(forName: suite) ?? [:], format: .xml, options: 0)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(text.contains("fixture-only"))
        XCTAssertFalse(text.contains("example.invalid"))
        XCTAssertFalse(text.contains(token.uuidString))
        XCTAssertFalse(text.contains(target.sessionID.uuidString))

        relaunched.bind(target)
        await relaunched.inspect { SessionControlReply($0, state: SessionControlSnapshot(token: token, mode: .rule, groups: [live])) }
        let request = try XCTUnwrap(relaunched.restoration(for: .access))
        XCTAssertEqual(request.member, unsafe)
        XCTAssertEqual(request.token, token)
        XCTAssertEqual(request.target, target)

        let replacement = SessionNodeList(group: .access, selected: "西区", preferred: nil, automatic: true, members: ["西区"])
        await relaunched.inspect { SessionControlReply($0, state: SessionControlSnapshot(token: UUID(), mode: .rule, groups: [replacement])) }
        XCTAssertNil(relaunched.restoration(for: .access))
        XCTAssertNotNil(relaunched.selectionError)
        XCTAssertNil(relaunched.offlineGroup(.access, names: members, source: .configuration).chosen)
        XCTAssertEqual(relaunched.previousGroups.first?.members, ["西区"])
        await relaunched.inspect { SessionControlReply($0, state: SessionControlSnapshot(token: UUID(), mode: .rule, groups: [])) }
        XCTAssertTrue(DesktopCoreControls(defaults: defaults).previousGroups.isEmpty)
    }

    func testExplicitAutomaticUnpinsOnlyAnExistingConfirmedAccessGroup() async throws {
        let suite = "FreeV6-AutoNodes-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("西区", forKey: "preferredNode.access")
        let controls = DesktopCoreControls(defaults: defaults)
        XCTAssertEqual(controls.offlineGroup(.access, names: ["东区", "西区"], source: .configuration).chosen, "西区")
        controls.saveNode(nil, in: .access)
        XCTAssertNil(defaults.string(forKey: "preferredNode.access"))
        XCTAssertNil(controls.restoration(for: .access))
        let current = SessionNodeList(group: .access, selected: "东区", preferred: "东区", automatic: true, members: ["东区", "西区"])
        let token = UUID()
        let target = SessionControlTarget(sessionID: UUID(), revision: 3)
        controls.bind(target)
        await controls.inspect { SessionControlReply($0, state: SessionControlSnapshot(token: token, mode: .rule, groups: [current])) }
        XCTAssertEqual(controls.restoration(for: .access)?.action, .unpin)
        XCTAssertEqual(controls.restoration(for: .access)?.token, token)
        XCTAssertNil(controls.restoration(for: .chain))
        controls.bind(nil)
        XCTAssertNil(controls.restoration(for: .access))
    }
}
