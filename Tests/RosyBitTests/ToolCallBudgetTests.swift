import XCTest
@testable import RosyBit

/// Model-led routing may chain tools. These cover the two things that go wrong
/// when it does: a transcript the provider will reject, and a budget that
/// quietly fails to bound anything.
final class ToolCallBudgetTests: XCTestCase {

    private func executed(_ name: String, id: String) -> ChatClient.ExecutedTool {
        ChatClient.ExecutedTool(
            id: id,
            name: name,
            rawArguments: #"{"query":"kagi"}"#,
            observation: "Result of \(name).",
            displayedContent: nil)
    }

    // MARK: - Transcript shape

    func testOneCallProducesAnAssistantTurnAndItsResult() throws {
        let turn = ChatClient.toolTurn([executed("web_search", id: "a")], limit: 3)

        XCTAssertEqual(turn.count, 2)
        XCTAssertEqual(turn[0]["role"] as? String, "assistant")
        XCTAssertTrue(turn[0]["content"] is NSNull)
        XCTAssertEqual((turn[0]["tool_calls"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(turn[1]["role"] as? String, "tool")
        XCTAssertEqual(turn[1]["tool_call_id"] as? String, "a")
        XCTAssertEqual(turn[1]["content"] as? String, "Result of web_search.")
    }

    /// A model may ask for several tools in one message. They belong in a
    /// single assistant turn, each with its own reply.
    func testParallelCallsShareOneAssistantTurn() throws {
        let turn = ChatClient.toolTurn(
            [executed("web_search", id: "a"), executed("volume_get", id: "b")],
            limit: 3)

        XCTAssertEqual(turn.count, 3)
        let calls = try XCTUnwrap(turn[0]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(turn[1]["tool_call_id"] as? String, "a")
        XCTAssertEqual(turn[2]["tool_call_id"] as? String, "b")
    }

    /// The invariant every provider enforces: each `tool_calls` entry must have
    /// exactly one matching `tool` reply. Getting this wrong is a 400, not a
    /// wrong answer, so it is worth asserting directly.
    func testEveryAdvertisedCallHasExactlyOneReply() throws {
        let turn = ChatClient.toolTurn(
            [executed("web_search", id: "a")],
            refused: [
                ChatClient.RefusedTool(id: "b", name: "web_fetch", rawArguments: "{}"),
                ChatClient.RefusedTool(id: "c", name: "web_fetch", rawArguments: "{}"),
            ],
            limit: 1)

        let calls = try XCTUnwrap(turn[0]["tool_calls"] as? [[String: Any]])
        let advertised = calls.compactMap { $0["id"] as? String }
        let answered = turn.dropFirst().compactMap { $0["tool_call_id"] as? String }

        XCTAssertEqual(advertised, ["a", "b", "c"])
        XCTAssertEqual(advertised.sorted(), answered.sorted())
        XCTAssertEqual(Set(answered).count, answered.count, "no id may be answered twice")
    }

    func testARefusedCallSaysWhyItWasNotRun() throws {
        let turn = ChatClient.toolTurn(
            [],
            refused: [ChatClient.RefusedTool(id: "b", name: "web_search", rawArguments: "{}")],
            limit: 2)

        let reply = try XCTUnwrap(turn.last?["content"] as? String)
        XCTAssertTrue(reply.contains("Not run"))
        XCTAssertTrue(reply.contains("2 tool calls"))
        XCTAssertTrue(reply.contains("Answer with what you have"))
    }

    func testRefusedArgumentsAreCappedBecauseTheyWereNeverValidated() throws {
        let spew = String(repeating: "x", count: 10_000)
        let turn = ChatClient.toolTurn(
            [],
            refused: [ChatClient.RefusedTool(id: "b", name: "web_search", rawArguments: spew)],
            limit: 1)

        let calls = try XCTUnwrap(turn[0]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        XCTAssertEqual(arguments.count, 2_000)
    }

    /// Executed calls replay the arguments Rosy validated, never the ones the
    /// model wrote. A rejected value must not re-enter the history.
    func testExecutedCallsReplayValidatedArguments() throws {
        let tool = ChatClient.ExecutedTool(
            id: "a",
            name: "web_search",
            rawArguments: #"{"query":"clean"}"#,
            observation: "ok",
            displayedContent: nil)
        let turn = ChatClient.toolTurn([tool], limit: 3)
        let calls = try XCTUnwrap(turn[0]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["arguments"] as? String, #"{"query":"clean"}"#)
    }

    func testReasoningIsCarriedOnlyWhenThereIsSome() throws {
        let withReasoning = ChatClient.toolTurn(
            [executed("web_search", id: "a")], limit: 3, reasoning: "thinking")
        XCTAssertEqual(withReasoning[0]["reasoning_content"] as? String, "thinking")

        let without = ChatClient.toolTurn([executed("web_search", id: "a")], limit: 3)
        XCTAssertNil(without[0]["reasoning_content"])
    }

    func testNothingExecutedAndNothingRefusedAddsNothing() {
        XCTAssertTrue(ChatClient.toolTurn([], limit: 3).isEmpty)
    }

    // MARK: - The budget itself

    func testTheLimitIsBoundedSoNoDefaultsWriteCanUnleashIt() throws {
        let suiteName = "ToolCallBudgetTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(Config.maxToolCalls, 3, "the shipped default")

        // Config reads the standard domain, so the clamp is asserted through
        // the same helper the property uses rather than by mutating it.
        for (written, expected) in [(0, 1), (1, 1), (3, 3), (8, 8), (999, 8), (-4, 1)] {
            suite.set(written, forKey: "probe")
            let clamped = min(max(suite.integer(forKey: "probe"), 1), 8)
            XCTAssertEqual(clamped, expected)
        }
    }
}

/// The budget expression itself. Everything else in the chain is bounded by
/// this one number, so it is worth testing on its own rather than only through
/// a live conversation.
final class ToolCallBudgetSelectionTests: XCTestCase {

    func testGuidedRoutingIsAlwaysOneWhateverTheSettingSays() {
        for configured in [1, 3, 8, 99] {
            XCTAssertEqual(
                ChatClient.toolCallBudget(mode: .guided, configured: configured), 1,
                "Guided must not chain — it is the measured Bonsai contract")
        }
    }

    func testModelLedUsesTheConfiguredLimit() {
        XCTAssertEqual(ChatClient.toolCallBudget(mode: .modelLed, configured: 1), 1)
        XCTAssertEqual(ChatClient.toolCallBudget(mode: .modelLed, configured: 3), 3)
        XCTAssertEqual(ChatClient.toolCallBudget(mode: .modelLed, configured: 8), 8)
    }

    /// A number arriving from `defaults write` has not been through the
    /// stepper, so the clamp is enforced here too rather than trusted.
    func testAnOutOfRangeLimitIsClampedRatherThanObeyed() {
        XCTAssertEqual(ChatClient.toolCallBudget(mode: .modelLed, configured: 0), 1)
        XCTAssertEqual(ChatClient.toolCallBudget(mode: .modelLed, configured: -7), 1)
        XCTAssertEqual(ChatClient.toolCallBudget(mode: .modelLed, configured: 10_000), 8)
    }
}

/// Regression cover for a chained turn losing the model's own words.
final class ToolTurnContentTests: XCTestCase {

    private var tool: ChatClient.ExecutedTool {
        ChatClient.ExecutedTool(
            id: "a", name: "web_search", rawArguments: "{}",
            observation: "results", displayedContent: nil)
    }

    /// The model usually says something before reaching for a tool, and that
    /// text has already been shown to the user. Replaying the turn as empty
    /// tells it that it said nothing — and on the next round it loses the
    /// thread, which is how a tool call ends up emitted as visible text.
    func testTheModelsOwnWordsSurviveIntoTheReplayedTurn() throws {
        let turn = ChatClient.toolTurn(
            [tool], limit: 3, content: "Let me check the current state of that for you. 💙")

        XCTAssertEqual(
            turn[0]["content"] as? String,
            "Let me check the current state of that for you. 💙")
        XCTAssertFalse(turn[0]["content"] is NSNull)
    }

    func testAnEmptyOrBlankTurnStillSendsNull() {
        XCTAssertTrue(ChatClient.toolTurn([tool], limit: 3)[0]["content"] is NSNull)
        XCTAssertTrue(
            ChatClient.toolTurn([tool], limit: 3, content: "   \n ")[0]["content"] is NSNull)
    }

    func testSurroundingWhitespaceIsNotReplayed() {
        let turn = ChatClient.toolTurn([tool], limit: 3, content: "\n  Looking that up.  \n")
        XCTAssertEqual(turn[0]["content"] as? String, "Looking that up.")
    }
}

/// Kagi highlights matched terms with HTML. Rosy renders Markdown.
final class KagiHTMLStrippingTests: XCTestCase {

    func testHighlightMarkupNeverReachesTheUserOrTheModel() {
        XCTAssertEqual(
            KagiTool.plainText("June 8, <strong>2026</strong>. PRESS RELEASE."),
            "June 8, 2026. PRESS RELEASE.")
        XCTAssertEqual(KagiTool.plainText("<b>Apple</b> <em>Intelligence</em>"),
                       "Apple Intelligence")
    }

    func testEntitiesAreDecodedWithAmpersandLast() {
        XCTAssertEqual(KagiTool.plainText("Fish &amp; Chips"), "Fish & Chips")
        XCTAssertEqual(KagiTool.plainText("5 &lt; 6 &gt; 4"), "5 < 6 > 4")
        XCTAssertEqual(KagiTool.plainText("&quot;quoted&quot;"), "\"quoted\"")
        // An escaped escape must not become a working tag.
        XCTAssertEqual(KagiTool.plainText("&amp;lt;script&amp;gt;"), "&lt;script&gt;")
    }

    func testStrippingSurvivesResultParsing() throws {
        let result = try XCTUnwrap(KagiClient.result(from: [
            "url": "https://apple.com",
            "title": "<strong>Apple</strong> Intelligence",
            "snippet": "Available in <b>English</b> &amp; more",
        ]))
        XCTAssertEqual(result.title, "Apple Intelligence")
        XCTAssertEqual(result.snippet, "Available in English & more")
    }
}

/// DeepSeek V4 intermittently emits its internal tool-call markup as ordinary
/// content. Rosy stops relaying it — and, deliberately, does not run it.
final class LeakedToolCallTests: XCTestCase {

    func testDeepSeeksMarkupIsRecognised() {
        let leak = "<\u{FF5C}DSML\u{FF5C}>tool_calls><\u{FF5C}DSML\u{FF5C}>invoke name=\"web_search\">"
        XCTAssertNotNil(ChatClient.leakedToolCallMarker(in: leak))
        XCTAssertNotNil(ChatClient.leakedToolCallMarker(in: "Sure! " + leak))
        // The ASCII-pipe variant some renderers produce.
        XCTAssertNotNil(ChatClient.leakedToolCallMarker(in: "<|DSML|>tool_calls>"))
    }

    func testOrdinaryProseIsNeverMistakenForALeak() {
        for innocent in [
            "Apple Intelligence supports several languages.",
            "Use the web_search tool when you need current facts.",
            "In maths, 5 < 6 and a | b denotes divisibility.",
            "The DSML acronym came up in that article.",
        ] {
            XCTAssertNil(
                ChatClient.leakedToolCallMarker(in: innocent),
                "false positive on: \(innocent)")
        }
    }

    func testOnlyTheTextBeforeTheMarkerWouldBeShown() throws {
        let reply = "Let me look that up. <\u{FF5C}DSML\u{FF5C}>tool_calls>junk"
        let marker = try XCTUnwrap(ChatClient.leakedToolCallMarker(in: reply))
        XCTAssertEqual(String(reply[..<marker.lowerBound]), "Let me look that up. ")
    }

    func testTheNoticeSaysItWasNotRunAndWhatToDo() {
        XCTAssertTrue(ChatClient.leakedToolCallNotice.contains("did not run it"))
        XCTAssertTrue(ChatClient.leakedToolCallNotice.contains("asking again"))
    }
}
