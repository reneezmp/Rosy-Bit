import Foundation
import XCTest
@testable import RosyBit

final class AskBarMarkdownTests: XCTestCase {

    func testRendersInlineMarkdownInsteadOfShowingDelimiters() {
        let rendered = AskBarMarkdown.render("**bold** · *italic* · `code`")

        XCTAssertEqual(String(rendered.characters), "bold · italic · code")

        let intents = rendered.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains { $0.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.emphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.code) })
    }

    func testIncompleteStreamingMarkdownStillProducesVisibleText() {
        let rendered = AskBarMarkdown.render("An answer with **unfinished emphasis")

        XCTAssertFalse(rendered.characters.isEmpty)
        XCTAssertTrue(String(rendered.characters).contains("unfinished emphasis"))
    }

    func testPreservesBlockStructureForNativeSwiftUIRendering() {
        let blocks = AskBarMarkdown.blocks("""
        # Heading

        A paragraph.

        - First
        - Second

        > Quoted

        ```swift
        let answer = 42
        ```
        """)

        XCTAssertEqual(
            blocks.map(\.kind),
            [.heading(1), .paragraph, .unorderedListItem, .unorderedListItem,
             .blockQuote, .codeBlock])
        XCTAssertEqual(String(blocks[0].content.characters), "Heading")
        XCTAssertEqual(String(blocks[2].content.characters), "First")
    }
}
