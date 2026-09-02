import XCTest
@testable import RosyBit

final class TimerToolTests: XCTestCase {
    func testExactTimerCreationParsesSimpleCompoundAndNamedDurations() {
        XCTAssertEqual(
            TimerTool.explicitCommand(in: "Set a timer for 12 minutes"),
            .create(duration: 720, label: nil))
        XCTAssertEqual(
            TimerTool.explicitCommand(in: "Start a tea timer for 1 hour and 30 minutes"),
            .create(duration: 5_400, label: "tea"))
        XCTAssertEqual(
            TimerTool.explicitCommand(in: "Set timer for 45 seconds, please"),
            .create(duration: 45, label: nil))
    }

    func testListAndCancellationCommandsAreDeterministic() {
        XCTAssertEqual(TimerTool.explicitCommand(in: "Show my timers"), .list)
        XCTAssertEqual(TimerTool.explicitCommand(in: "Cancel my tea timer"), .cancel(label: "tea"))
        XCTAssertEqual(TimerTool.explicitCommand(in: "Stop the timer"), .cancel(label: nil))
        XCTAssertEqual(TimerTool.explicitCommand(in: "Cancel all timers"), .cancelAll)
    }

    func testInvalidDurationIsCaughtLocallyAndTextIsNotTreatedAsACommand() {
        XCTAssertEqual(
            TimerTool.explicitCommand(in: "Set a timer for 9 weeks"),
            .rejectedDuration("9 weeks"))
        XCTAssertEqual(
            TimerTool.explicitCommand(in: "Set a timer for 0 seconds"),
            .rejectedDuration("0 seconds"))
        XCTAssertNil(TimerTool.explicitCommand(in: "Timers are useful for cooking."))
        XCTAssertNil(TimerTool.explicitCommand(in: "Instructions:\nSet a timer for 10 seconds"))
    }

    func testTimerListIsEmptyInAnIsolatedStore() throws {
        let suiteName = "TimerToolTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            TimerTool.listResult(defaults: suite),
            "There are no active Rosy timers.")
    }

    func testModelFacingTimerSchemaIsReadOnly() throws {
        let schema = try XCTUnwrap(TimerTool.schema.first)
        let function = try XCTUnwrap(schema["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "timer_list")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual((parameters["properties"] as? [String: Any])?.count, 0)
    }
}
