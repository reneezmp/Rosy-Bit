import XCTest
@testable import RosyBit

final class SkillSettingsTests: XCTestCase {
    func testSkillsDefaultOnAndPersistIndependently() throws {
        let suiteName = "SkillSettingsTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SkillSettings.isEnabled(.dictionary, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.volumeControl, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.calculatorUnits, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.timers, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.batterySystem, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.appsFinder, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.fileSearch, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.reminders, defaults: suite))

        SkillSettings.setEnabled(false, for: .dictionary, defaults: suite)
        XCTAssertFalse(SkillSettings.isEnabled(.dictionary, defaults: suite))
        XCTAssertTrue(SkillSettings.isEnabled(.volumeControl, defaults: suite))
    }

    func testAllSkillsOffProducesNoToolSchemas() {
        let schemas = SkillSettings.schemas(
            isCloud: true,
            modelName: nil,
            dictionaryEnabled: false,
            volumeEnabled: false,
            calculatorEnabled: false,
            timersEnabled: false,
            systemEnabled: false,
            appsFinderEnabled: false,
            fileSearchEnabled: false,
            remindersEnabled: false,
            routingMode: .guided)

        XCTAssertTrue(schemas.isEmpty)
    }

    func testEachSkillContributesOnlyItsOwnSchema() throws {
        let dictionary = SkillSettings.schemas(
            isCloud: true,
            modelName: nil,
            dictionaryEnabled: true,
            volumeEnabled: false,
            calculatorEnabled: false,
            timersEnabled: false,
            systemEnabled: false,
            appsFinderEnabled: false,
            fileSearchEnabled: false,
            remindersEnabled: false,
            routingMode: .guided)
        let volume = SkillSettings.schemas(
            isCloud: true,
            modelName: nil,
            dictionaryEnabled: false,
            volumeEnabled: true,
            calculatorEnabled: false,
            timersEnabled: false,
            systemEnabled: false,
            appsFinderEnabled: false,
            fileSearchEnabled: false,
            remindersEnabled: false,
            routingMode: .guided)

        XCTAssertEqual(try toolName(in: dictionary), DictionaryTool.name)
        XCTAssertEqual(try toolName(in: volume), VolumeTool.name)
    }

    func testNewSkillsEachContributeOnlyTheirOwnSchema() throws {
        let common: (Bool, Bool, Bool) -> [[String: Any]] = { calculator, timers, system in
            SkillSettings.schemas(
                isCloud: true,
                modelName: nil,
                dictionaryEnabled: false,
                volumeEnabled: false,
                calculatorEnabled: calculator,
                timersEnabled: timers,
                systemEnabled: system,
                appsFinderEnabled: false,
                fileSearchEnabled: false,
                remindersEnabled: false,
                routingMode: .guided)
        }
        XCTAssertEqual(try toolName(in: common(true, false, false)), CalculatorTool.name)
        XCTAssertEqual(try toolName(in: common(false, true, false)), TimerTool.name)
        XCTAssertEqual(try toolName(in: common(false, false, true)), SystemStatusTool.name)
    }

    func testMacSkillsEachContributeOnlyTheirOwnSchema() throws {
        func schemas(apps: Bool, files: Bool, reminders: Bool) -> [[String: Any]] {
            SkillSettings.schemas(
                isCloud: true,
                modelName: nil,
                dictionaryEnabled: false,
                volumeEnabled: false,
                calculatorEnabled: false,
                timersEnabled: false,
                systemEnabled: false,
                appsFinderEnabled: apps,
                fileSearchEnabled: files,
                remindersEnabled: reminders,
                routingMode: .guided)
        }
        XCTAssertEqual(try toolName(in: schemas(apps: true, files: false, reminders: false)), AppsFinderTool.name)
        XCTAssertEqual(try toolName(in: schemas(apps: false, files: true, reminders: false)), FileSearchTool.name)
        XCTAssertEqual(try toolName(in: schemas(apps: false, files: false, reminders: true)), RemindersTool.name)
    }

    func testUnmeasuredLocalModelRequiresExplicitModelLedRouting() {
        XCTAssertTrue(SkillSettings.schemas(
            isCloud: false,
            modelName: "Bonsai-4B-Q1_0.gguf",
            dictionaryEnabled: true,
            volumeEnabled: true,
            calculatorEnabled: true,
            timersEnabled: true,
            systemEnabled: true,
            appsFinderEnabled: true,
            fileSearchEnabled: true,
            remindersEnabled: true,
            routingMode: .guided).isEmpty)
        XCTAssertFalse(SkillSettings.schemas(
            isCloud: false,
            modelName: "Large-Unmeasured-Model.gguf",
            dictionaryEnabled: true,
            volumeEnabled: true,
            calculatorEnabled: true,
            timersEnabled: true,
            systemEnabled: true,
            appsFinderEnabled: true,
            fileSearchEnabled: true,
            remindersEnabled: true,
            routingMode: .modelLed).isEmpty)
    }

    private func toolName(in schemas: [[String: Any]]) throws -> String {
        let schema = try XCTUnwrap(schemas.first)
        let function = try XCTUnwrap(schema["function"] as? [String: Any])
        return try XCTUnwrap(function["name"] as? String)
    }
}
