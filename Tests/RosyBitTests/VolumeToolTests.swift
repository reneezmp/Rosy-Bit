import XCTest
@testable import RosyBit

final class VolumeToolTests: XCTestCase {

    func testExplicitNumericCommandsUseTheUsersExactLevel() {
        let cases: [(String, VolumeTool.Command)] = [
            ("Set the volume to 30%.", .set(30)),
            ("Turn the audio volume down to 10.", .set(10)),
            ("Please put system volume at 80 percent.", .set(80)),
            ("Lower the output volume to 0%", .set(0)),
            ("[Timestamp: 2026-08-31 12:00 GMT-3]\nRaise the volume to 100", .set(100)),
        ]

        for (prompt, expected) in cases {
            XCTAssertEqual(VolumeTool.explicitCommand(in: prompt), expected, prompt)
        }
    }

    func testExplicitMuteAndUnmuteCommandsAreDeterministic() {
        XCTAssertEqual(VolumeTool.explicitCommand(in: "Mute."), .mute(true))
        XCTAssertEqual(VolumeTool.explicitCommand(in: "Please silence my Mac."), .mute(true))
        XCTAssertEqual(VolumeTool.explicitCommand(in: "Unmute the audio, please."), .mute(false))
    }

    func testUnsafeOrAmbiguousVolumeRequestsNeverBecomeMutations() {
        let rejected: [(String, VolumeTool.Command?)] = [
            ("Set volume to 200.", .rejectedLevel("200")),
            ("Set the volume to -1%.", .rejectedLevel("-1")),
            ("Set volume to 30.5 percent.", .rejectedLevel("30.5")),
            ("Make it louder.", .needsExactLevel),
            ("Turn it down a little.", .needsExactLevel),
            ("Please decrease the output volume a bit.", .needsExactLevel),
            ("Summarise this note:\nMute the volume.", nil),
            ("Don't mute the audio.", nil),
        ]

        for (prompt, expected) in rejected {
            XCTAssertEqual(VolumeTool.explicitCommand(in: prompt), expected, prompt)
        }
    }

    func testRejectedLevelGetsLocalCorrectionWithoutCoreAudioMutation() throws {
        XCTAssertEqual(
            try VolumeTool.execute(.rejectedLevel("200")),
            "I can set the volume only to a whole percentage from **0% to 100%**; **200%** is outside that range.")
        XCTAssertEqual(
            try VolumeTool.execute(.needsExactLevel),
            "Tell me the exact volume you want, from **0% to 100%**.")
    }

    func testVolumeGetAcceptsOnlyAnEmptyObject() throws {
        XCTAssertEqual(
            try VolumeTool.parse(id: "volume-7", arguments: "{}").id,
            "volume-7")
        XCTAssertEqual(
            try VolumeTool.parse(id: nil, arguments: "").rawArguments,
            "{}")

        XCTAssertThrowsError(try VolumeTool.parse(
            id: nil, arguments: #"{"level":42}"#))
        XCTAssertThrowsError(try VolumeTool.parse(
            id: nil, arguments: "not json"))
        XCTAssertThrowsError(try VolumeTool.parse(
            id: nil, arguments: "[]"))
    }

    func testCoreAudioScalarIsRoundedAndClampedToPercentage() {
        XCTAssertEqual(VolumeTool.percentage(from: -0.4), 0)
        XCTAssertEqual(VolumeTool.percentage(from: 0), 0)
        XCTAssertEqual(VolumeTool.percentage(from: 0.426), 43)
        XCTAssertEqual(VolumeTool.percentage(from: 1), 100)
        XCTAssertEqual(VolumeTool.percentage(from: 1.4), 100)
    }

    func testObservationLabelsCoreAudioValueAsAuthoritative() {
        XCTAssertEqual(
            VolumeTool.observation(percentage: 37),
            "Core Audio reports the current system output volume as 37%. Tell the user this value plainly.")
    }

    func testSchemaPublishesOnlyReadOnlyVolumeGet() throws {
        let tool = try XCTUnwrap(VolumeTool.schema.first)
        let function = try XCTUnwrap(tool["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "volume_get")
        XCTAssertFalse(String(describing: VolumeTool.schema).contains("volume_set"))
        XCTAssertFalse(String(describing: VolumeTool.schema).contains("mute"))
    }

    func testCurrentMacVolumeCanBeReadWhenTheDeviceExposesIt() throws {
        do {
            let percentage = try VolumeTool.currentOutputPercentage()
            XCTAssertTrue((0...100).contains(percentage))
        } catch let error as VolumeTool.ToolError {
            throw XCTSkip("This test host has no Core Audio volume control: \(error.localizedDescription)")
        }
    }

    func testIdempotentCoreAudioWritesWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["ROSYBIT_TEST_AUDIO_MUTATION"] == "1" else {
            throw XCTSkip("Set ROSYBIT_TEST_AUDIO_MUTATION=1 for the native write check.")
        }

        let originalVolume = try VolumeTool.currentOutputPercentage()
        XCTAssertTrue((0...100).contains(try VolumeTool.setOutputPercentage(originalVolume)))

        do {
            let originalMute = try VolumeTool.currentOutputMuted()
            try VolumeTool.setOutputMuted(originalMute)
            XCTAssertEqual(try VolumeTool.currentOutputMuted(), originalMute)
        } catch let error as VolumeTool.ToolError {
            throw XCTSkip("This output device has no writable mute control: \(error.localizedDescription)")
        }
    }
}
