import XCTest
@testable import RosyBit

/// Not a test: a way to get the real schema block out of the app for
/// experiments. Writes nothing unless ROSYBIT_DUMP_SCHEMAS is set.
final class DumpSchemasTests: XCTestCase {
    func testDumpSchemas() throws {
        guard let path = ProcessInfo.processInfo.environment["ROSYBIT_DUMP_SCHEMAS"] else {
            throw XCTSkip("set ROSYBIT_DUMP_SCHEMAS=<path>")
        }
        let schemas = SkillSettings.schemas(
            isCloud: false, modelName: nil, isAppleFoundationModel: true,
            dictionaryEnabled: true, volumeEnabled: true, calculatorEnabled: true,
            timersEnabled: true, systemEnabled: true, appsFinderEnabled: true,
            fileSearchEnabled: true, remindersEnabled: true, webSearchEnabled: true,
            routingMode: .modelLed)
        let data = try JSONSerialization.data(
            withJSONObject: schemas, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(schemas.count) schemas")
    }
}
