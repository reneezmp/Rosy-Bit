import XCTest
@testable import RosyBit

final class AppsFinderToolTests: XCTestCase {
    func testExplicitCommandsAreNarrowAndTimestampAware() {
        XCTAssertEqual(AppsFinderTool.explicitCommand(in: "Open Safari"), .openApp("Safari"))
        XCTAssertEqual(AppsFinderTool.explicitCommand(in: "Open the Safari app"), .openApp("Safari"))
        XCTAssertEqual(AppsFinderTool.explicitCommand(in: "Quit Notes"), .quitApp("Notes"))
        XCTAssertEqual(AppsFinderTool.explicitCommand(in: "Open my Downloads folder"), .openFolder(.downloads))
        XCTAssertEqual(
            AppsFinderTool.explicitCommand(in: "[Timestamp: 2026-09-01 09:00 GMT-3]\nReveal ~/Desktop/test.txt in Finder"),
            .reveal("~/Desktop/test.txt"))
        XCTAssertNil(AppsFinderTool.explicitCommand(in: "Safari is a web browser."))
        XCTAssertNil(AppsFinderTool.explicitCommand(in: "Instructions:\nOpen Safari"))
    }

    func testLookupArgumentsAreStrict() throws {
        XCTAssertEqual(try AppsFinderTool.parse(id: nil, arguments: #"{"query":"Safari"}"#).query, "Safari")
        XCTAssertThrowsError(try AppsFinderTool.parse(id: nil, arguments: #"{"query":"Safari","open":true}"#))
    }
}
