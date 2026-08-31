import XCTest
@testable import RosyBit

final class DictionaryToolTests: XCTestCase {

    func testToolIsGatedToMeasuredBonsaiBuild() {
        XCTAssertTrue(DictionaryTool.isAvailable(for: "Bonsai-1.7B-Q1_0.gguf"))
        XCTAssertTrue(DictionaryTool.isAvailable(for: "bonsai_1.7b_q1_0.gguf"))
        XCTAssertFalse(DictionaryTool.isAvailable(for: "Bonsai-4B-Q1_0.gguf"))
        XCTAssertFalse(DictionaryTool.isAvailable(for: "Bonsai-1.7B-Q2_0.gguf"))
        XCTAssertFalse(DictionaryTool.isAvailable(for: nil))
    }

    func testStrictlyParsesOneDictionaryTerm() throws {
        let call = try DictionaryTool.parse(
            id: "call-7",
            name: "dictionary_lookup",
            arguments: #"{"term":"  susurrus  "}"#)

        XCTAssertEqual(call.id, "call-7")
        XCTAssertEqual(call.term, "susurrus")
    }

    func testRejectsUnknownToolsAndLooseArguments() {
        XCTAssertThrowsError(try DictionaryTool.parse(
            id: nil, name: "volume_set", arguments: #"{"term":"quiet"}"#))
        XCTAssertThrowsError(try DictionaryTool.parse(
            id: nil, name: "dictionary_lookup", arguments: #"{"term":"quiet","extra":true}"#))
        XCTAssertThrowsError(try DictionaryTool.parse(
            id: nil, name: "dictionary_lookup", arguments: #"{"term":""}"#))
        XCTAssertThrowsError(try DictionaryTool.parse(
            id: nil, name: "dictionary_lookup", arguments: "not json"))
    }

    func testEntryAndGlossRemainVisiblySeparate() {
        let output = DictionaryTool.displayedEntry(
            term: "susurrus",
            definition: "A whispering or rustling sound.")

        XCTAssertTrue(output.contains("### Dictionary: susurrus"))
        XCTAssertTrue(output.contains("```\nA whispering or rustling sound.\n```"))
        XCTAssertTrue(output.contains("### Rosy’s gloss"))
    }

    func testDictionaryFenceOutgrowsBackticksInsideEntry() {
        let output = DictionaryTool.displayedEntry(
            term: "code",
            definition: "Written as ```swift inside the entry.")

        XCTAssertTrue(output.contains("````\nWritten as ```swift inside the entry.\n````"))
    }

    func testLongEntriesAreBoundedBeforeDisplayAndObservation() {
        let longDefinition = String(repeating: "A very expansive dictionary sense. ", count: 200)
        let excerpt = DictionaryTool.boundedDefinition(longDefinition)
        let display = DictionaryTool.displayedEntry(term: "faire", definition: longDefinition)
        let observation = DictionaryTool.observation(term: "faire", definition: longDefinition)

        XCTAssertTrue(excerpt.wasShortened)
        XCTAssertLessThan(excerpt.text.count, DictionaryTool.maximumDefinitionCharacters + 50)
        XCTAssertTrue(excerpt.text.contains("entry shortened by Rosy Bit"))
        XCTAssertTrue(display.contains("Entry shortened locally"))
        XCTAssertFalse(display.contains(longDefinition))
        XCTAssertTrue(observation.contains("locally shortened excerpt"))
        XCTAssertFalse(observation.contains(longDefinition))
    }

    func testShortEntriesRemainUntouched() {
        let definition = "A compact definition."
        let excerpt = DictionaryTool.boundedDefinition(definition)

        XCTAssertEqual(excerpt.text, definition)
        XCTAssertFalse(excerpt.wasShortened)
    }

    func testMissingEntryIsStatedRatherThanInvented() {
        let display = DictionaryTool.displayedEntry(term: "notaword", definition: nil)
        let observation = DictionaryTool.observation(term: "notaword", definition: nil)

        XCTAssertTrue(display.contains("No entry was found"))
        XCTAssertTrue(observation.contains("do not invent a definition"))
    }
}
