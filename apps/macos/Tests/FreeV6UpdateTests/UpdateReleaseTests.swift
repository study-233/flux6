import Foundation
import XCTest
@testable import FreeV6UpdateSupport

final class UpdateReleaseTests: XCTestCase {
    private var fields: [String: Any] {
        ["format": 1, "build": 2, "minimumSourceBuild": 1, "maximumSourceBuild": 1,
         "architecture": UpdateRelease.architecture, "workerProtocol": 1, "serviceProtocol": 6,
         "settingsSchema": 1, "runtimeCatalogSHA256": String(repeating: "a", count: 64),
         "serviceSHA256": String(repeating: "b", count: 64)]
    }

    func testCompatibilityRequiresArchitectureProtocolsAndSignedReleaseFields() throws {
        let release = try UpdateRelease.decode(JSONSerialization.data(withJSONObject: fields), currentBuild: 1)
        XCTAssertEqual(release.build, 2)
        for (key, value): (String, Any) in [("format", 2), ("build", 1), ("minimumSourceBuild", 2), ("maximumSourceBuild", 0),
                                          ("architecture", "other"), ("workerProtocol", 2), ("serviceProtocol", 999),
                                          ("settingsSchema", 2), ("runtimeCatalogSHA256", ""), ("serviceSHA256", "../../file")] {
            var invalid = fields
            invalid[key] = value
            XCTAssertThrowsError(try UpdateRelease.decode(JSONSerialization.data(withJSONObject: invalid), currentBuild: 1), key)
        }
    }

    func testChannelRequiresExplicitKeysSignedFeedAndSecureOrigin() throws {
        let url = "https://updates.example.invalid/appcast-" + UpdateRelease.architecture + ".xml"
        var info: [String: Any] = ["CFBundleVersion": "1", "SUFeedURL": url,
                                 "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
                                 "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
                                 "SURelaunchHostBundle": true,
                                 "SUSignedFeedFailureExpirationInterval": 0, "SUAllowsAutomaticUpdates": false]
        XCTAssertEqual(try UpdateChannel(info: info).feed.absoluteString, url)
        for name in ["SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUSignedFeedFailureExpirationInterval"] {
            var invalid = info
            invalid.removeValue(forKey: name)
            XCTAssertThrowsError(try UpdateChannel(info: invalid), name)
        }
        info["SUFeedURL"] = "http://127.0.0.1:1234/appcast-" + UpdateRelease.architecture + ".xml"
        XCTAssertThrowsError(try UpdateChannel(info: info))
        XCTAssertNoThrow(try UpdateChannel(info: info, allowLoopback: true))
    }

    func testPrivatePipeFramesPreserveOperationIdentityAndRejectPartialOrOversizeData() throws {
        let event = UpdateEvent(.ready, operation: UUID(), release: try UpdateRelease.decode(JSONSerialization.data(withJSONObject: fields), currentBuild: 1))
        let pipe = Pipe()
        try UpdatePipe.write(event, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let read = try XCTUnwrap(UpdatePipe.read(UpdateEvent.self, from: pipe.fileHandleForReading))
        XCTAssertEqual(read.operation, event.operation)
        XCTAssertEqual(read.release, event.release)
        XCTAssertNil(try UpdatePipe.read(UpdateEvent.self, from: pipe.fileHandleForReading))
        try pipe.fileHandleForReading.close()
        for bytes: [UInt8] in [[0, 0, 64, 1], [0, 0, 0, 4, 123]] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data(bytes))
            try pipe.fileHandleForWriting.close()
            XCTAssertThrowsError(try UpdatePipe.read(UpdateEvent.self, from: pipe.fileHandleForReading))
            try pipe.fileHandleForReading.close()
        }
    }
}
