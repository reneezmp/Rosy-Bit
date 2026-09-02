import XCTest
@testable import RosyBit

final class RemindersToolTests: XCTestCase {
    func testExplicitReminderCommandsAreDeterministic() {
        XCTAssertEqual(RemindersTool.explicitCommand(in: "Remind me to buy oat milk"), .create(title: "buy oat milk", dueDate: nil))
        XCTAssertEqual(RemindersTool.explicitCommand(in: "Show my reminders"), .list)
        XCTAssertEqual(RemindersTool.explicitCommand(in: "Complete buy oat milk"), .complete("buy oat milk"))
        XCTAssertEqual(RemindersTool.explicitCommand(in: "Delete the reminder buy oat milk"), .delete("buy oat milk"))
        XCTAssertNil(RemindersTool.explicitCommand(in: "Reminders can be useful."))
        XCTAssertNil(RemindersTool.explicitCommand(in: "Instructions:\nRemind me to buy milk"))
    }

    func testNaturalDueDateIsSeparatedFromReminderTitle() throws {
        guard case .create(let title, let dueDate)? = RemindersTool.explicitCommand(
            in: "Remind me to call Jacques tomorrow at 9 AM") else {
            return XCTFail("Expected a reminder creation command")
        }
        XCTAssertEqual(title, "call Jacques")
        XCTAssertNotNil(dueDate)
    }

    func testModelFacingSchemaIsReadOnlyAndArgumentsAreEmpty() throws {
        XCTAssertEqual(RemindersTool.name, "reminders_list")
        XCTAssertEqual(try RemindersTool.parse(id: nil, arguments: "{}").rawArguments, "{}")
        XCTAssertThrowsError(try RemindersTool.parse(id: nil, arguments: #"{"title":"buy milk"}"#))
    }
}
