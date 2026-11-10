import XCTest
import FreeV6Business

final class ProxyRuleIssueTests: XCTestCase {
    func testRejectedLineMapsToOriginalTextAfterBlankLinesAndCRLF() throws {
        let text = "ok.example\r\n\r\nhttps://bad.example\r\n后续.example"
        let issue = try XCTUnwrap(ProxyRuleIssue.locate(in: text, field: .blacklist))
        XCTAssertEqual(issue.line, 3)
        XCTAssertEqual((text as NSString).substring(with: issue.range), "https://bad.example")
        XCTAssertTrue(issue.reason.contains("移除"))
    }

    func testCampusNetworksAndBareDomains() throws {
        let valid = "Edu.CN\n 202.204.0.0/12 \n2001:db8::/48"
        XCTAssertNil(ProxyRuleIssue.locate(in: valid, field: .campus))
        let issue = try XCTUnwrap(ProxyRuleIssue.locate(in: valid + "\n2001:db8::/150", field: .campus))
        XCTAssertEqual(issue.field, .campus)
        XCTAssertEqual(issue.line, 4)
        XCTAssertEqual(ProxyRuleIssue.locate(in: "invalid_domain.example", field: .blacklist)?.line, 1)
    }
}
