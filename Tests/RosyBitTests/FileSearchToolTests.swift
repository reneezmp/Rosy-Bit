import XCTest
@testable import RosyBit

final class FileSearchToolTests: XCTestCase {
    func testExplicitSearchGrammarIsBounded() {
        XCTAssertEqual(FileSearchTool.explicitFilenameQuery(in: "Find files named lesson plan"), "lesson plan")
        XCTAssertNil(FileSearchTool.explicitQuery(in: "Find files named lesson plan"))
        XCTAssertEqual(FileSearchTool.explicitQuery(in: "Search my Mac for RosyBit.zip"), "RosyBit.zip")
        XCTAssertNil(FileSearchTool.explicitQuery(in: "I need to find my direction in life."))
        XCTAssertNil(FileSearchTool.explicitQuery(in: "Find this:\nsecret"))
    }

    func testFilenameSearchRejectsContentOnlyMatches() {
        let paths = [
            "/project/README.md",
            "/project/RosyBit.zip",
            "/project/RosyBit.app",
            "/project/CHANGELOG.md"
        ]
        XCTAssertEqual(
            FileSearchTool.filteredPaths(paths, query: "RosyBit", filenamesOnly: true),
            ["/project/RosyBit.zip", "/project/RosyBit.app"])
        XCTAssertEqual(
            FileSearchTool.filteredPaths(paths, query: "RosyBit", filenamesOnly: false),
            paths)
    }

    func testSearchArgumentsAreStrict() throws {
        XCTAssertEqual(try FileSearchTool.parse(id: nil, arguments: #"{"query":"RosyBit"}"#).query, "RosyBit")
        XCTAssertThrowsError(try FileSearchTool.parse(id: nil, arguments: #"{"query":"RosyBit","limit":1000}"#))
        XCTAssertThrowsError(try FileSearchTool.parse(id: nil, arguments: #"{"query":""}"#))
    }
}
