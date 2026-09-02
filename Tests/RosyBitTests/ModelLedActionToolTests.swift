import XCTest
@testable import RosyBit

final class ModelLedActionToolTests: XCTestCase {
    func testGuidedIsDefaultAndRoutingChoicePersists() throws {
        let name = "ModelLedActionToolTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(SkillSettings.routingMode(defaults: defaults), .guided)
        SkillSettings.setRoutingMode(.modelLed, defaults: defaults)
        XCTAssertEqual(SkillSettings.routingMode(defaults: defaults), .modelLed)
        SkillSettings.setRoutingMode(.guided, defaults: defaults)
        XCTAssertEqual(SkillSettings.routingMode(defaults: defaults), .guided)
    }

    func testGuidedOmitsActionsAndModelLedAddsOnlyEnabledActions() throws {
        func names(mode: SkillSettings.RoutingMode, volume: Bool, timers: Bool, apps: Bool, reminders: Bool) -> Set<String> {
            Set(SkillSettings.schemas(
                isCloud: true, modelName: nil,
                dictionaryEnabled: false,
                volumeEnabled: volume,
                calculatorEnabled: false,
                timersEnabled: timers,
                systemEnabled: false,
                appsFinderEnabled: apps,
                fileSearchEnabled: false,
                remindersEnabled: reminders,
                routingMode: mode).compactMap { schema in
                    (schema["function"] as? [String: Any])?["name"] as? String
                })
        }

        XCTAssertEqual(names(mode: .guided, volume: false, timers: false, apps: false, reminders: false), [])
        XCTAssertEqual(
            names(mode: .modelLed, volume: true, timers: false, apps: false, reminders: false),
            [VolumeTool.name, ModelLedActionTool.volumeName])
        XCTAssertEqual(
            names(mode: .modelLed, volume: false, timers: true, apps: true, reminders: true),
            [TimerTool.name, AppsFinderTool.name, RemindersTool.name,
             ModelLedActionTool.timerName, ModelLedActionTool.appsFinderName,
             ModelLedActionTool.remindersName])
    }

    func testUnsafeActionArgumentsAreRejectedBeforeNativeMutation() async {
        await assertMalformed(name: ModelLedActionTool.volumeName, #"{"action":"set","level":101}"#)
        await assertMalformed(name: ModelLedActionTool.volumeName, #"{"action":"set","level":true}"#)
        await assertMalformed(name: ModelLedActionTool.timerName, #"{"action":"create","duration_seconds":999999999}"#)
        await assertMalformed(name: ModelLedActionTool.appsFinderName, #"{"action":"open_folder","target":"root"}"#)
        await assertMalformed(name: ModelLedActionTool.remindersName, #"{"action":"create","title":"test","due_at":"eventually"}"#)
        await assertMalformed(name: ModelLedActionTool.remindersName, #"{"action":"delete","title":"x","extra":true}"#)
    }

    private func assertMalformed(name: String, _ arguments: String) async {
        do {
            _ = try await ModelLedActionTool.execute(id: nil, name: name, arguments: arguments)
            XCTFail("Expected malformed arguments for \(name)")
        } catch {
            XCTAssertEqual(error as? ModelLedActionTool.ToolError, .malformedArguments)
        }
    }
}
