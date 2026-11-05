import XCTest
@testable import FreeV6Business

final class CampusIPv6Tests: XCTestCase {
    func testCampusPrefixesAndEquivalentSpellings() async throws {
        for ip in ["2001:DA8::1\n", "2001:0da8:ffff::", " 2001:0250:0000:0000:0000:0000:0000:0001 "] {
            try await CampusIPv6.check(developerMode: false) { ip }
        }
    }

    func testRejectsOtherPrefixesAndInvalidEcho() async {
        for (ip, expected) in [("2001:da9::1", CampusNetworkError.outsideCampus), ("2001:251::", .outsideCampus),
                               ("::ffff:127.0.0.1", .outsideCampus), ("2001:da8:::0", .invalidResponse),
                               ("2001:da8::1\u{0}more", .invalidResponse), ("<html>", .invalidResponse)] {
            do { try await CampusIPv6.check(developerMode: false) { ip }; XCTFail("unexpected allowance") }
            catch { XCTAssertEqual(error as? CampusNetworkError, expected) }
        }
    }

    func testEchoReadsBoundedHTTPResponseUsingTheFixedEndpoint() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CampusEchoFixture.self]
        let result = try await CampusIPv6.readAddress(using: config)
        XCTAssertEqual(result, "2001:da8::1")
        config.protocolClasses = [OversizedEchoFixture.self]
        do {
            _ = try await CampusIPv6.readAddress(using: config)
            XCTFail("oversized echo accepted")
        } catch { XCTAssertEqual(error as? CampusNetworkError, .invalidResponse) }
    }

    func testDeveloperModeSkipsExternalLookup() async throws {
        try await CampusIPv6.check(developerMode: true) { XCTFail("unexpected public lookup"); return "" }
    }
}

private class CampusEchoFixture: URLProtocol {
    var body: String { "2001:da8::1" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.absoluteString == "https://api-ipv6.ip.sb/ip",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OversizedEchoFixture: CampusEchoFixture {
    override var body: String { String(repeating: "a", count: 129) }
}
