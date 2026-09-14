import XCTest
@testable import RosyBit

final class InferenceSourceTests: XCTestCase {
    func testUnsetKeyMeansLocal() throws {
        let suite = "InferenceSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(InferenceSource.current(defaults), .local)
    }

    /// The three selections are one exclusive choice sharing one key, so
    /// picking the on-device model has to be visible as "not cloud" without
    /// anyone remembering to clear a second flag.
    func testSelectingAppleDeselectsCloud() throws {
        let suite = "InferenceSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cloud", forKey: InferenceSource.defaultsKey)

        let cloud = CloudModelStore(defaults: defaults)
        XCTAssertTrue(cloud.isCloudSelected)

        InferenceSource.set(.apple, defaults)
        cloud.refreshSelection()
        XCTAssertFalse(cloud.isCloudSelected)

        let apple = AppleModelStore(defaults: defaults)
        XCTAssertTrue(apple.isSelected)
    }

    /// Forgetting a cloud profile must not drag inference back to a GGUF when
    /// the user's actual selection is Apple's model.
    func testForgettingCloudLeavesAppleSelected() throws {
        let suite = "InferenceSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CloudProviderConfiguration(
            kind: .custom,
            name: "My Cloud",
            endpoint: "https://example.com/v1/chat/completions",
            model: "qwen-cloud",
            maxTokens: 1024)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "cloudProviderConfiguration")
        defaults.set("apple", forKey: InferenceSource.defaultsKey)

        CloudModelStore(defaults: defaults).forget()
        XCTAssertEqual(InferenceSource.current(defaults), .apple)
    }
}

final class AppleFoundationModelTests: XCTestCase {

    /// The ask bar's shape. Labelling a lone question "User:" only teaches the
    /// model to answer in a transcript voice, so it is passed through bare.
    func testSingleQuestionIsPassedThroughUnlabelled() {
        let (instructions, prompt) = AppleFoundationModel.flatten([
            ["role": "system", "content": "Answer briefly."],
            ["role": "user", "content": "What is a bonsai?"],
        ])
        XCTAssertEqual(instructions, "Answer briefly.")
        XCTAssertEqual(prompt, "What is a bonsai?")
    }

    func testMultipleTurnsAreLabelled() {
        let (instructions, prompt) = AppleFoundationModel.flatten([
            ["role": "user", "content": "Hello"],
            ["role": "assistant", "content": "Hi."],
            ["role": "user", "content": "Again?"],
        ])
        XCTAssertNil(instructions)
        XCTAssertEqual(prompt, "User: Hello\n\nRosy: Hi.\n\nUser: Again?")
    }

    /// Rosy runs the deterministic skills herself and hands the result over as
    /// evidence. It has to arrive labelled as retrieval rather than as
    /// something the assistant already said.
    func testToolResultsBecomeRetrievedInformation() {
        let (_, prompt) = AppleFoundationModel.flatten([
            ["role": "user", "content": "define plinth"],
            ["role": "tool", "content": "plinth — a heavy base."],
        ])
        XCTAssertEqual(
            prompt,
            "User: define plinth\n\nRetrieved information:\nplinth — a heavy base.")
    }

    /// An assistant turn that only asked for a tool carries `NSNull` content in
    /// the OpenAI shape. It must not surface as the string "<null>".
    func testNullAssistantContentIsDropped() {
        let (_, prompt) = AppleFoundationModel.flatten([
            ["role": "user", "content": "define plinth"],
            ["role": "assistant", "content": NSNull(), "tool_calls": []],
            ["role": "tool", "content": "plinth — a heavy base."],
        ])
        XCTAssertFalse(prompt.contains("null"))
        XCTAssertTrue(prompt.hasPrefix("User: define plinth"))
    }

    // MARK: - Stitching cumulative snapshots

    /// The ordinary case: each snapshot is the whole answer so far, so only the
    /// new tail travels.
    func testCumulativeSnapshotYieldsOnlyTheNewTail() {
        XCTAssertEqual(
            AppleFoundationModel.segmentDelta(
                snapshot: "A bonsai is a tree", shown: "A bonsai", hasSpoken: true),
            " is a tree")
    }

    func testUnchangedSnapshotYieldsNothing() {
        XCTAssertNil(
            AppleFoundationModel.segmentDelta(
                snapshot: "A bonsai", shown: "A bonsai", hasSpoken: true))
        XCTAssertNil(
            AppleFoundationModel.segmentDelta(snapshot: "", shown: "", hasSpoken: false))
    }

    /// A tool call ends one segment and begins another, and the new one does
    /// not continue the old text. It is separated rather than appended blindly,
    /// or its first Markdown heading never starts a line.
    func testFreshSegmentIsSeparatedFromWhatWasAlreadySaid() {
        XCTAssertEqual(
            AppleFoundationModel.segmentDelta(
                snapshot: "### Definition", shown: "Let me look that up.", hasSpoken: true),
            "\n\n### Definition")
    }

    /// Nothing has been said yet, so there is nothing to separate it from.
    func testFirstSegmentGetsNoLeadingBreak() {
        XCTAssertEqual(
            AppleFoundationModel.segmentDelta(
                snapshot: "Hello", shown: "", hasSpoken: false),
            "Hello")
    }

    /// The reason `Result.text` accumulates deltas instead of taking the last
    /// snapshot: replacing it leaves the record holding only the closing half
    /// of an answer the reader saw in full, and on this runtime that record is
    /// the only trace the answer leaves.
    func testAccumulatedDeltasReproduceTheWholeAnswerAcrossAToolCall() {
        let snapshots = ["Let me", "Let me look that up.", "### Definition", "### Definition\nA tree."]
        var shown = ""
        var hasSpoken = false
        var accumulated = ""
        for snapshot in snapshots {
            guard let delta = AppleFoundationModel.segmentDelta(
                snapshot: snapshot, shown: shown, hasSpoken: hasSpoken) else { continue }
            accumulated += delta
            shown = snapshot
            hasSpoken = true
        }
        XCTAssertEqual(accumulated, "Let me look that up.\n\n### Definition\nA tree.")
        XCTAssertNotEqual(accumulated, snapshots.last)
    }

    func testSeveralSystemMessagesBecomeOneSetOfInstructions() {
        let (instructions, prompt) = AppleFoundationModel.flatten([
            ["role": "system", "content": "Be brief."],
            ["role": "system", "content": "Be warm."],
            ["role": "user", "content": "Hi"],
        ])
        XCTAssertEqual(instructions, "Be brief.\n\nBe warm.")
        XCTAssertEqual(prompt, "Hi")
    }
}

final class PrefixBudgetTests: XCTestCase {

    /// The three parts are measured by difference precisely so they add up.
    /// A readout whose lines do not sum to its own total reads as a bug.
    func testPartsSumToTotal() {
        let measurement = PrefixBudget.Measurement(
            total: 229, systemPrompt: 16, toolSchema: 201, template: 12, contextSize: 2048)
        XCTAssertEqual(
            measurement.systemPrompt + measurement.toolSchema + measurement.template,
            measurement.total)
    }

    func testPercentOfContextIsRounded() {
        XCTAssertEqual(
            PrefixBudget.Measurement(
                total: 229, systemPrompt: 16, toolSchema: 201, template: 12,
                contextSize: 2048).percentOfContext,
            11)
    }

    func testZeroContextDoesNotDivideByZero() {
        XCTAssertEqual(
            PrefixBudget.Measurement(
                total: 229, systemPrompt: 16, toolSchema: 201, template: 12,
                contextSize: 0).percentOfContext,
            0)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
final class AppleToolBridgeTests: XCTestCase {

    /// Every schema Rosy can advertise, with every skill on and the fuller
    /// Model-led action set included.
    private var everySchema: [[String: Any]] {
        SkillSettings.schemas(
            isCloud: true,
            modelName: nil,
            dictionaryEnabled: true,
            volumeEnabled: true,
            calculatorEnabled: true,
            timersEnabled: true,
            systemEnabled: true,
            appsFinderEnabled: true,
            fileSearchEnabled: true,
            remindersEnabled: true,
            webSearchEnabled: true,
            routingMode: .modelLed)
    }

    /// `tools(from:)` drops anything it cannot translate rather than failing a
    /// whole request, which is the right trade at runtime and a silent hole in
    /// a test suite. This is the check that closes it: every real schema must
    /// survive, so a new skill with an untranslatable parameter fails here
    /// rather than quietly disappearing from the on-device model's reach.
    func testEveryRosySchemaTranslates() throws {
        let schemas = everySchema
        XCTAssertGreaterThan(schemas.count, 8, "the fixture stopped covering the skills")

        let bridged = AppleToolBridge.tools(from: schemas) { _, _ in "" }
        XCTAssertEqual(
            bridged.count,
            schemas.count,
            "a schema was dropped in translation")

        let originalNames = schemas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(bridged.map(\.name).sorted(), originalNames.sorted())
    }

    func testEnumsBecomeChoicesAndBoundsBecomeGuides() throws {
        // The shape `ModelLedActionTool` uses: a string enum beside a bounded
        // integer. Both have exact equivalents, so neither may throw.
        let parameters: [String: Any] = [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["set", "mute", "unmute"]],
                "level": ["type": "integer", "minimum": 0, "maximum": 100],
            ],
            "required": ["action"],
        ]
        XCTAssertNoThrow(
            try AppleToolBridge.generationSchema(name: "volume", parameters: parameters))
    }

    /// A skill with no arguments at all — Timers and Reminders both ship one.
    func testEmptyParameterObjectTranslates() throws {
        XCTAssertNoThrow(try AppleToolBridge.generationSchema(
            name: "empty",
            parameters: ["type": "object", "properties": [String: Any]()]))
    }

    /// An unknown type is refused rather than guessed at: a parameter the model
    /// is told the wrong shape of produces arguments Rosy will reject anyway.
    func testUnknownTypeIsRefused() {
        let parameters: [String: Any] = [
            "type": "object",
            "properties": ["when": ["type": "date-time"]],
        ]
        XCTAssertThrowsError(
            try AppleToolBridge.generationSchema(name: "odd", parameters: parameters))
    }

    /// Prefix reuse everywhere else in this app depends on the tool block being
    /// byte-stable, and Swift dictionaries are unordered.
    func testPropertyOrderIsStable() throws {
        let parameters: [String: Any] = [
            "type": "object",
            "properties": [
                "zeta": ["type": "string"], "alpha": ["type": "string"],
                "mid": ["type": "string"], "beta": ["type": "string"],
            ],
            "required": ["alpha"],
        ]
        let first = try AppleToolBridge.generationSchema(name: "s", parameters: parameters)
        let second = try AppleToolBridge.generationSchema(name: "s", parameters: parameters)
        XCTAssertEqual(String(describing: first), String(describing: second))
    }
}
#endif

final class OnDeviceBudgetTests: XCTestCase {

    /// Measured by difference, so the three parts must reconstruct the total —
    /// the same contract the llama-server reading holds itself to.
    func testMeasuredPartsSumToTotal() {
        let measured = AppleFoundationModel.PrefixMeasurement(
            total: 708, instructions: 42, toolSchema: 610, framing: 56)
        XCTAssertEqual(
            measured.instructions + measured.toolSchema + measured.framing,
            measured.total)
    }

    /// Characters are the free reading and must stand on their own before any
    /// measurement has been taken — opening the menu bar must never require it.
    func testUnmeasuredReadingStillCarriesCharacters() {
        let device = PrefixBudget.OnDevice(
            systemPromptCharacters: 190,
            lastInputTokens: nil,
            measured: nil,
            canMeasure: true)
        XCTAssertEqual(device.systemPromptCharacters, 190)
        XCTAssertNil(device.measured)
    }
}

/// The cost of a second set of descriptions is that it can rot while the first
/// one moves. These are what make that cost bounded.
final class AppleToolDescriptionTests: XCTestCase {

    private var everySchemaName: Set<String> {
        Set(SkillSettings.schemas(
            isCloud: true, modelName: nil,
            dictionaryEnabled: true, volumeEnabled: true, calculatorEnabled: true,
            timersEnabled: true, systemEnabled: true, appsFinderEnabled: true,
            fileSearchEnabled: true, remindersEnabled: true, webSearchEnabled: true,
            routingMode: .modelLed
        ).compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }

    /// The drift guard. A renamed or removed skill leaves an override pointing
    /// at nothing, which would silently stop applying and leave the on-device
    /// model back on the hedged wording that measured 15/30.
    func testEveryOverrideNamesARealTool() {
        let unknown = Set(AppleToolDescriptions.overrides.keys)
            .subtracting(everySchemaName)
        XCTAssertTrue(
            unknown.isEmpty,
            "these overrides name tools that no longer exist: \(unknown.sorted())")
    }

    /// Sparse on purpose: a tool that did not need rewording keeps the shared
    /// description, so there is one place to edit rather than two.
    func testUnlistedToolsKeepTheSharedDescription() {
        XCTAssertEqual(
            AppleToolDescriptions.description(for: "calculator_calculate", shared: "shared"),
            "shared")
        XCTAssertNil(AppleToolDescriptions.overrides["calculator_calculate"])
        XCTAssertNil(AppleToolDescriptions.overrides["dictionary_lookup"])
    }

    /// The overrides exist for the on-device path alone. Leaking them into the
    /// shared schema block would change the prefix every other runtime is
    /// measured against — the exact risk this whole approach was chosen to avoid.
    func testOverridesDoNotLeakIntoTheSharedSchemas() {
        let shared = SkillSettings.schemas(
            isCloud: true, modelName: nil, volumeEnabled: true, routingMode: .modelLed)
        let volumeControl = shared.first {
            ($0["function"] as? [String: Any])?["name"] as? String == "volume_control"
        }
        let description = ((volumeControl?["function"]) as? [String: Any])?["description"] as? String
        XCTAssertNotNil(description)
        XCTAssertNotEqual(description, AppleToolDescriptions.overrides["volume_control"])
        XCTAssertTrue(description?.contains("Use only when") == true)
    }

    #if canImport(FoundationModels)
    /// And the bridge must actually apply them, or all of the above is theatre.
    @available(macOS 26.0, *)
    func testBridgeAppliesTheOverride() throws {
        let schemas = SkillSettings.schemas(
            isCloud: true, modelName: nil, volumeEnabled: true, routingMode: .modelLed)
        let bridged = AppleToolBridge.tools(from: schemas) { _, _ in "" }
        let volumeControl = try XCTUnwrap(bridged.first { $0.name == "volume_control" })
        XCTAssertEqual(
            volumeControl.description, AppleToolDescriptions.overrides["volume_control"])
    }
    #endif
}
