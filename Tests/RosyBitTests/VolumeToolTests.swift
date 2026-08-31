import XCTest
@testable import RosyBit

final class VolumeToolTests: XCTestCase {

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
}
