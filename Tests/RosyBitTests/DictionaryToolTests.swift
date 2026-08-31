import XCTest
@testable import RosyBit

final class DictionaryToolTests: XCTestCase {

    func testExplicitDefinitionRequestsRouteWithoutAskingTheModel() {
        let cases = [
            ("What does susurrus mean?", "susurrus"),
            ("What's the meaning of the word 'lurking'?", "lurking"),
            ("What is the definition of “Renée”?", "Renée"),
            ("Define the word verisimilitude please.", "verisimilitude"),
            ("Can you tell me the meaning of the term 'liminal'?", "liminal"),
            ("I need a definition for 'recalcitrant'.", "recalcitrant"),
            ("[Timestamp: 2026-08-31 11:00 GMT-3]\nmeaning of defenestration?", "defenestration"),
        ]

        for (prompt, expected) in cases {
            XCTAssertEqual(
                DictionaryTool.explicitLookupTerm(in: prompt),
                expected,
                prompt)
        }
    }

    func testAmbiguousUsesOfMeaningStayWithTheModel() {
        let prompts = [
            "What do you mean?",
            "What does it mean when my cat chirps?",
            "That was a mean thing to say.",
            "What is the meaning of life?",
            "Explain why this sentence is meaningful.",
            "What's the origin of susurrus?",
            "Summarise this note:\nDefine cat",
        ]

        for prompt in prompts {
            XCTAssertNil(DictionaryTool.explicitLookupTerm(in: prompt), prompt)
        }
    }

    func testRoutedCallProducesStrictlyParseableArguments() throws {
        let routed = DictionaryTool.routedCall(term: #"say "hello""#)
        let parsed = try DictionaryTool.parse(
            id: routed.id,
            name: DictionaryTool.name,
            arguments: routed.rawArguments)

        XCTAssertEqual(parsed.term, #"say "hello""#)
    }

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

    func testFlatDictionaryArticleGetsReadableSenseAndExampleBreaks() {
        let source = "sabbath | ˈsabəθ | noun 1 (often the Sabbath) a day of religious observance: we observe the Sabbath | [as modifier] : sabbath candles | sabbath law. 2 a supposed midnight meeting held by witches. ORIGIN Old English sabat."
        let formatted = DictionaryTool.formattedDefinitionForDisplay(source)

        XCTAssertTrue(formatted.contains("sabbath | ˈsabəθ |\n\nnoun\n\n1 "))
        XCTAssertTrue(formatted.contains("observance:\n    we observe the Sabbath"))
        XCTAssertTrue(formatted.contains("\n    | [as modifier] :\n    sabbath candles"))
        XCTAssertTrue(formatted.contains("sabbath law.\n\n2 a supposed"))
        XCTAssertTrue(formatted.contains("\n\nORIGIN\nOld English"))
    }

    func testBulletSensesAndLaterPartsOfSpeechGetSeparateBlocks() {
        let source = "lust | lʌst | noun [mass noun] strong desire: his lust returned. ● [in singular] a passionate desire: a lust for power. verb [no object] have strong desire: they lusted after power."
        let formatted = DictionaryTool.formattedDefinitionForDisplay(source)

        XCTAssertTrue(formatted.contains("returned.\n\n● [in singular]"))
        XCTAssertTrue(formatted.contains("power.\n\nverb [no object]"))
        XCTAssertTrue(formatted.contains("desire:\n    they lusted"))
    }

    func testDisplayFormattingChangesWhitespaceButNoSourceCharacters() {
        let source = "word | wɜːd | noun 1 a unit of language: a written word | a spoken word. 2 a promise. DERIVATIVES wordless."
        let formatted = DictionaryTool.formattedDefinitionForDisplay(source)

        XCTAssertEqual(collapsingWhitespace(formatted), collapsingWhitespace(source))
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

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
