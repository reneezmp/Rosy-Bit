import Foundation
import XCTest
@testable import RosyBit

final class MessageAndModelDisplayTests: XCTestCase {

    func testUserMessageGetsCompactLocalTimestampWithoutChangingOtherRoles() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .iso8601)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 8
        components.day = 30
        components.hour = 16
        components.minute = 45
        components.second = 12

        let date = try XCTUnwrap(components.date)
        let local = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        let message = ChatClient.Message.user("What time is it?", at: date, timeZone: local)

        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.content, "[Timestamp: 2026-08-30 13:45 BRT]\nWhat time is it?")
        XCTAssertEqual(ChatClient.Message.system("Stable").content, "Stable")
        XCTAssertEqual(ChatClient.Message.assistant("Answer").content, "Answer")
    }

    func testInstalledModelMenuTitleIncludesActualFileSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = directory.appendingPathComponent("Tiny-Q1_0.gguf")
        try Data(repeating: 0, count: 1_500).write(to: model)

        let title = ModelStore.menuTitle(for: model)
        XCTAssertTrue(title.hasPrefix("Tiny-Q1_0 — "), title)
        XCTAssertFalse(title.contains(".gguf"), title)
        XCTAssertNotEqual(title, "Tiny-Q1_0")
    }
}
