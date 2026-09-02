import XCTest
@testable import RosyBit

final class SystemStatusToolTests: XCTestCase {
    func testExplicitSystemQuestionsMapToOneMetric() {
        XCTAssertEqual(
            SystemStatusTool.explicitMetric(in: "What's my battery percentage?"),
            .battery)
        XCTAssertEqual(
            SystemStatusTool.explicitMetric(in: "Am I plugged in?"),
            .powerSource)
        XCTAssertEqual(
            SystemStatusTool.explicitMetric(in: "How much storage is left?"),
            .storage)
        XCTAssertEqual(
            SystemStatusTool.explicitMetric(in: "How much RAM does this Mac have?"),
            .memory)
    }

    func testRouterRejectsProseAndPastedInstructions() {
        XCTAssertNil(SystemStatusTool.explicitMetric(
            in: "Battery technology has changed enormously."))
        XCTAssertNil(SystemStatusTool.explicitMetric(
            in: "Notes from work\nWhat's my battery percentage?"))
    }

    func testArgumentsRequireExactlyOneAllowlistedMetric() throws {
        XCTAssertEqual(
            try SystemStatusTool.parse(
                id: nil,
                arguments: #"{"metric":"storage"}"#).metric,
            .storage)
        XCTAssertThrowsError(try SystemStatusTool.parse(
            id: nil,
            arguments: #"{"metric":"temperature"}"#))
        XCTAssertThrowsError(try SystemStatusTool.parse(
            id: nil,
            arguments: #"{"metric":"storage","path":"/"}"#))
    }

    func testMemoryAndStorageReturnBoundedNativeFacts() throws {
        XCTAssertTrue(try SystemStatusTool.result(for: .memory).contains("physical memory"))
        XCTAssertTrue(try SystemStatusTool.result(for: .storage).contains("startup disk"))
        XCTAssertTrue(try SystemStatusTool.result(for: .powerSource).contains("currently using"))
    }

    func testBatteryReadsWhenTheHostExposesOne() throws {
        do {
            let result = try SystemStatusTool.result(for: .battery)
            XCTAssertTrue(result.contains("Battery is"))
        } catch SystemStatusTool.ToolError.unavailable {
            throw XCTSkip("This test host does not expose an internal battery.")
        }
    }
}
