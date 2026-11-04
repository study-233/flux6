import Foundation
import XCTest
@testable import FreeV6System

final class ServiceInstallationRequestTests: XCTestCase {
    func testRequiresInstalledApplicationAndValidIdentity() throws {
        let hash = String(repeating: "a", count: 40)
        XCTAssertThrowsError(try ServiceInstallationRequest(action: .install,
            app: URL(fileURLWithPath: "/Volumes/FreeV6/FreeV6.app"), uid: 501, clientHash: hash))
        XCTAssertThrowsError(try ServiceInstallationRequest(action: .install,
            app: URL(fileURLWithPath: "/Applications/FreeV6.app"), uid: 0, clientHash: hash))
        XCTAssertThrowsError(try ServiceInstallationRequest(action: .install,
            app: URL(fileURLWithPath: "/Applications/FreeV6.app"), uid: 501, clientHash: "injected"))
        let request = try ServiceInstallationRequest(action: .install,
            app: URL(fileURLWithPath: "/Applications/FreeV6.app"), uid: 501, clientHash: hash)
        XCTAssertEqual(request.arguments, ["install", "/Applications/FreeV6.app", "501", hash])
        XCTAssertEqual(request.executable.path, "/Applications/FreeV6.app/Contents/Helpers/freev6-service-installer")
    }

    func testShellArgumentsRemainLiteral() throws {
        for value in ["a b", "O'Reilly", "$(printf WRONG)", "`printf WRONG`", "a; printf WRONG", "\"quote\"\\path", "line\nbreak"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' " + ServiceInstallationRequest.shellQuote(value)]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value)
        }
    }

    func testAppleScriptEscapesItsOwnStringLiteral() throws {
        let request = try ServiceInstallationRequest(action: .install,
            app: URL(fileURLWithPath: "/Applications/FreeV6 \"test\".app"), uid: 501,
            clientHash: String(repeating: "a", count: 40))
        XCTAssertTrue(request.appleScript.contains("\\\"test\\\""))
        XCTAssertTrue(request.appleScript.hasSuffix("with administrator privileges"))
    }
}
