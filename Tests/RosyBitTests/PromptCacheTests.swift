import XCTest
@testable import RosyBit

final class PromptCacheTests: XCTestCase {

    func testServerLaunchIncludesBoundedEphemeralPromptCache() throws {
        let arguments = Config.serverArguments(modelPath: "/tmp/model.gguf", alias: "test")

        let ramIndex = try XCTUnwrap(arguments.firstIndex(of: "--cache-ram"))
        let checkpointIndex = try XCTUnwrap(arguments.firstIndex(of: "--checkpoint-min-step"))
        XCTAssertGreaterThanOrEqual(Int(arguments[ramIndex + 1]) ?? -1, 0)
        XCTAssertLessThanOrEqual(Int(arguments[ramIndex + 1]) ?? .max, 2048)
        XCTAssertGreaterThanOrEqual(Int(arguments[checkpointIndex + 1]) ?? -1, 64)
        XCTAssertTrue(arguments.contains("--ctx-checkpoints"))
        XCTAssertFalse(arguments.contains("--slot-save-path"))
    }

    func testPromptCacheChangesRequireServerRestart() {
        let original = SettingsValues()
        var changed = original
        changed.promptCacheRAM += 64
        XCTAssertTrue(changed.needsServerRestart(comparedTo: original))

        changed = original
        changed.promptCacheCheckpointTokens += 64
        XCTAssertTrue(changed.needsServerRestart(comparedTo: original))
    }
}
