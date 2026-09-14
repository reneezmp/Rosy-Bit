import Combine
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which runtime answers Rosy's own questions.
///
/// One key rather than a pair of booleans, because the three are exclusive and
/// two flags would let a build reach a state that has no meaning. Persisted
/// under the name the cloud work already used, so an existing preference keeps
/// its meaning across the upgrade.
enum InferenceSource: String {
    case local
    case cloud
    case apple

    static let defaultsKey = "inferenceSource"

    static func current(_ defaults: UserDefaults = .standard) -> InferenceSource {
        defaults.string(forKey: defaultsKey)
            .flatMap(InferenceSource.init(rawValue:)) ?? .local
    }

    static func set(_ source: InferenceSource, _ defaults: UserDefaults = .standard) {
        defaults.set(source.rawValue, forKey: defaultsKey)
    }
}

/// Apple's on-device model, offered as one more *local* model rather than as a
/// separate category.
///
/// It is the odd one out in this app: Rosy exists because a fanless Core m3
/// running Ventura has no Apple Intelligence and never will, so on the machine
/// this project was written for none of this code ever runs. It is here for the
/// M4 — where the model is already downloaded, already resident, and answers in
/// a fraction of the time a 1-bit GGUF on two Intel cores can.
///
/// Deliberately narrow for a first version:
///
///  * **No context-size setting.** `Config.contextSize` is a `llama-server`
///    flag and has nothing to say here. The framework publishes no context
///    length at all — `LanguageModelCapabilities` reports features, not token
///    counts — so there is no honest number to put in a field, and inventing
///    one would only be wrong at the next OS release. An overflow is reported
///    with whatever figure the system itself gives, which on macOS 26 is none
///    and on macOS 27 is the real one.
///  * **A fresh session per request.** Rosy replays the whole conversation on
///    every turn, so a session that also kept its own transcript would send the
///    history twice.
enum AppleFoundationModel {

    /// What the Model menu calls it. Apple's own naming for the thing users
    /// switch on in macOS System Settings, not the framework's class name.
    static let title = "Apple Intelligence — on-device"

    enum Readiness: Equatable {
        /// The framework is here and the model will answer.
        case available
        /// This Mac could run it, but something is switched off or still
        /// downloading. Worth showing, greyed out, with the reason.
        case unavailable(String)
        /// Not this OS, not this Mac. Nothing to show at all.
        case unsupported
    }

    static var readiness: Readiness {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            // An Intel Mac, or an Apple Silicon Mac Apple has ruled out. Not a
            // setting anyone can change, so it is not offered as one.
            return .unsupported
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn Apple Intelligence on in macOS System Settings.")
        case .unavailable(.modelNotReady):
            return .unavailable("The system model is still downloading.")
        case .unavailable:
            return .unavailable("The system model is unavailable.")
        }
        #else
        return .unsupported
        #endif
    }

    static var isAvailable: Bool { readiness == .available }

    enum ModelError: LocalizedError {
        case unavailable(String)
        case contextExceeded(tokens: Int?, limit: Int?)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return reason
            case .contextExceeded(let tokens, let limit):
                guard let tokens, let limit else {
                    return "The conversation is longer than Apple's on-device model "
                        + "can hold. Start a new chat, or ask a shorter question."
                }
                return "The conversation is \(tokens) tokens and Apple's on-device "
                    + "model holds \(limit). Start a new chat, or ask a shorter question."
            }
        }
    }

    // MARK: - Prompting

    /// Flattens Rosy's OpenAI-shaped conversation into the two things a
    /// `LanguageModelSession` takes: standing instructions and one prompt.
    ///
    /// The common case — a single question from the ask bar — passes through as
    /// the bare question, because labelling one line "User:" only teaches the
    /// model to answer in a transcript voice. Anything longer gets the labels,
    /// which is the cheapest way to keep turn boundaries legible without
    /// building a `Transcript` by hand.
    static func flatten(
        _ conversation: [[String: Any]]
    ) -> (instructions: String?, prompt: String) {
        var instructions: [String] = []
        var turns: [(role: String, text: String)] = []

        for message in conversation {
            let role = message["role"] as? String ?? ""
            let text = (message["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if role == "system" {
                if !text.isEmpty { instructions.append(text) }
            } else if !text.isEmpty {
                turns.append((role, text))
            }
        }

        let joinedInstructions = instructions.isEmpty
            ? nil
            : instructions.joined(separator: "\n\n")

        if turns.count == 1, turns[0].role == "user" {
            return (joinedInstructions, turns[0].text)
        }

        let prompt = turns.map { turn in
            switch turn.role {
            case "user": return "User: \(turn.text)"
            case "assistant": return "Rosy: \(turn.text)"
            // Retrieved evidence, not something anyone said. Labelled so the
            // model quotes it rather than treating it as a previous answer.
            case "tool": return "Retrieved information:\n\(turn.text)"
            default: return turn.text
            }
        }.joined(separator: "\n\n")

        return (joinedInstructions, prompt)
    }

    // MARK: - Measuring the prefix

    /// What Rosy puts in front of a question, in Apple's own tokens.
    struct PrefixMeasurement: Sendable, Equatable {
        /// Everything before the question, including the one-character stand-in
        /// the measurement uses in its place.
        let total: Int
        let instructions: Int
        let toolSchema: Int
        /// Apple's own scaffolding plus that stand-in character. The counterpart
        /// of the chat template on the llama-server path: not something any
        /// setting controls, but the parts do not sum to the total without it.
        let framing: Int
    }

    /// Measures the prefix by asking the model to read it.
    ///
    /// There is no tokeniser to call and no context length published, so for a
    /// long time the honest readout here was a character count. There is a way
    /// round it, and it is Renée's: send a one-character prompt and read
    /// `usage.input`, which is Apple's own count of everything it was given.
    /// The dot stands in for a question that has not been typed yet.
    ///
    /// Three probes rather than one, for the same reason the llama-server path
    /// renders four templates — the parts are differences. Each generates a
    /// single token and the reply is thrown away, so this costs about a second
    /// warm and is cached until the prefix itself changes.
    ///
    /// Needs macOS 27: `usage` does not exist before it, and without a real
    /// number this would be exactly the estimate it exists to avoid.
    @available(macOS 27.0, *)
    static func measurePrefix(
        instructions: String?,
        toolSchemas: [[String: Any]]
    ) async -> PrefixMeasurement? {
        let options = GenerationOptions(maximumResponseTokens: 1)

        func inputTokens(
            instructions: String?,
            tools: [any FoundationModels.Tool]
        ) async -> Int? {
            let session = LanguageModelSession(tools: tools, instructions: instructions)
            // The answer is discarded. Only what the model was handed matters,
            // and it does not count that until it has been asked something.
            _ = try? await session.respond(to: ".", options: options)
            let counted = session.usage.input.totalTokenCount
            return counted > 0 ? counted : nil
        }

        guard let framing = await inputTokens(instructions: nil, tools: []) else { return nil }
        if Task.isCancelled { return nil }

        // Skip a probe that cannot differ from the one before it rather than
        // spending a generation to prove a zero.
        let withInstructions: Int
        if instructions?.isEmpty == false {
            guard let measured = await inputTokens(instructions: instructions, tools: [])
            else { return nil }
            withInstructions = measured
        } else {
            withInstructions = framing
        }
        if Task.isCancelled { return nil }

        let total: Int
        if toolSchemas.isEmpty {
            total = withInstructions
        } else {
            let tools = AppleToolBridge.tools(from: toolSchemas) { _, _ in "" }
            guard let measured = await inputTokens(instructions: instructions, tools: tools)
            else { return nil }
            total = measured
        }

        return PrefixMeasurement(
            total: total,
            instructions: max(0, withInstructions - framing),
            toolSchema: max(0, total - withInstructions),
            framing: framing)
    }

    // MARK: - Generation

    struct Result {
        var text = ""
        var firstTokenAt: Date?
        var completionTokens: Int?
        /// What Apple's own model counted as input, which is the only real
        /// token figure this framework ever publishes — and only from macOS 27.
        var inputTokens: Int?
        /// Every tool the framework ran, in order. Rosy never sees these as
        /// they happen — the loop is not hers — so they are collected on the
        /// way past for Insights to show afterwards.
        var toolRuns: [ToolRun] = []
    }

    struct ToolRun: Sendable {
        let name: String
        let arguments: String
        let observation: String
    }

    /// Collects tool runs across one answer. An actor for the same reason the
    /// budget is one: FoundationModels may call tools off any thread.
    private actor ToolLog {
        private(set) var runs: [ToolRun] = []
        func append(_ run: ToolRun) { runs.append(run) }
    }

    /// A tool the model asked for, in the same shape an HTTP provider would
    /// have produced: a name and a JSON argument string. Rosy's existing
    /// parsers take it from here.
    struct ToolCall: Sendable {
        let name: String
        let arguments: String
    }

    /// What running it produced: what the model is told, and what the reader
    /// is shown, which are deliberately not the same thing.
    struct ToolOutcome: Sendable {
        let observation: String
        let displayed: String?
    }

    /// Counts tool calls across one answer.
    ///
    /// An actor because FoundationModels runs the loop itself and may call
    /// `Tool.call` concurrently — Rosy's own loop, where the budget was a
    /// local `var`, does not exist on this path.
    private actor Budget {
        private var spent = 0
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func claim() -> Bool {
            guard spent < limit else { return false }
            spent += 1
            return true
        }

        var refusal: String {
            let plural = limit == 1 ? "" : "s"
            return "Not run. Rosy Bit allows \(limit) tool call\(plural) for one "
                + "answer and that is already spent. Answer with what you have."
        }
    }

    /// The visible difference between a cumulative snapshot and what has
    /// already been shown, or `nil` when there is nothing new to send.
    ///
    /// `ResponseStream` yields cumulative snapshots — each one is the whole
    /// answer so far — so ordinarily the new tail is what gets sent on. A tool
    /// call can end one segment and begin another, though, and a fresh segment
    /// does not continue the old text: it is separated from what was already
    /// said rather than appended blindly, which is why this is a prefix check
    /// and not a bare `dropFirst`.
    ///
    /// Pure, and outside `stream`, so the stitching can be tested without a
    /// model. Appending every delta it returns reproduces exactly what the
    /// reader saw, which is what `Result.text` has to hold.
    static func segmentDelta(snapshot: String, shown: String, hasSpoken: Bool) -> String? {
        if snapshot.hasPrefix(shown) {
            guard snapshot.count > shown.count else { return nil }
            return String(snapshot.dropFirst(shown.count))
        }
        guard !snapshot.isEmpty else { return nil }
        return hasSpoken ? "\n\n" + snapshot : snapshot
    }

    /// Streams one answer, calling `onDelta` on the main thread with each new
    /// fragment.
    ///
    /// `ResponseStream` yields cumulative snapshots rather than deltas — each
    /// one is the whole answer so far — so the difference against what has
    /// already been shown is what gets sent on. Anything else would repeat the
    /// reply once per token.
    static func stream(
        conversation: [[String: Any]],
        toolSchemas: [[String: Any]] = [],
        budget: Int = 0,
        execute: (@Sendable (ToolCall) async throws -> ToolOutcome)? = nil,
        onDelta: @escaping (String) -> Void
    ) async throws -> Result {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw ModelError.unavailable("Apple's on-device model needs macOS 26 or later.")
        }
        switch readiness {
        case .available:
            break
        case .unavailable(let reason):
            throw ModelError.unavailable(reason)
        case .unsupported:
            throw ModelError.unavailable("This Mac has no Apple Intelligence model.")
        }

        let (instructions, prompt) = flatten(conversation)

        // FoundationModels runs the tool loop itself: it generates, sees a
        // call, invokes `Tool.call`, appends the result and carries on, all
        // inside the one `streamResponse`. So the budget, the refusal, and
        // showing retrieved evidence to the reader all have to live inside the
        // tool rather than around a loop Rosy no longer owns.
        // `onDelta` is a main-actor callback, and FoundationModels' tool loop
        // has to reach it from off the main actor. Every call already goes
        // through `MainActor.run`, so the closure only ever runs where it was
        // made; the sink carries it across that boundary without making every
        // caller of `ChatClient.send` adopt `@Sendable`.
        let sink = DeltaSink(onDelta)
        let allowance = Budget(limit: budget)
        let toolLog = ToolLog()
        // Tracks whether the model has said anything yet, so a retrieved block
        // is not welded onto the end of a sentence. Same reason as `show` on
        // the HTTP path.
        let spoken = SpokenFlag()
        var tools: [any FoundationModels.Tool] = []
        if let execute, budget > 0, !toolSchemas.isEmpty {
            tools = AppleToolBridge.tools(from: toolSchemas) { name, arguments in
                guard await allowance.claim() else { return await allowance.refusal }
                let outcome = try await execute(ToolCall(name: name, arguments: arguments))
                await toolLog.append(ToolRun(
                    name: name, arguments: arguments, observation: outcome.observation))
                if let displayed = outcome.displayed {
                    let separated = await spoken.value ? "\n\n" + displayed : displayed
                    await sink.emit(separated)
                }
                return outcome.observation
            }
        }

        let session = LanguageModelSession(tools: tools, instructions: instructions)

        var result = Result()
        var shown = ""
        // A local mirror of `spoken`. The actor exists so the tool closure can
        // read this from whatever thread FoundationModels calls it on; the loop
        // is the only writer, so it need not hop per token to ask itself.
        var hasSpoken = false
        // No `maximumResponseTokens`: the framework decides what fits, and a
        // ceiling picked here would only be a second, worse context limit.
        let options = GenerationOptions(temperature: Config.temperature)

        do {
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                if Task.isCancelled { throw CancellationError() }
                let text = snapshot.content
                guard let delta = segmentDelta(
                    snapshot: text, shown: shown, hasSpoken: hasSpoken) else { continue }
                if result.firstTokenAt == nil { result.firstTokenAt = Date() }
                shown = text
                // Accumulated from the deltas rather than replaced by the
                // snapshot. A fresh segment does not carry what was said before
                // it, so assigning here would leave the record holding only the
                // closing half of an answer the reader saw in full — and on this
                // runtime the record is the only trace there is.
                result.text += delta
                hasSpoken = true
                await spoken.raise()
                await sink.emit(delta)
                if #available(macOS 27.0, *) {
                    result.completionTokens = snapshot.usage.output.totalTokenCount
                    result.inputTokens = snapshot.usage.input.totalTokenCount
                }
            }
        } catch let error as ModelError {
            throw error
        } catch {
            throw translate(error)
        }
        result.toolRuns = await toolLog.runs
        return result
        #else
        throw ModelError.unavailable("This build has no FoundationModels framework.")
        #endif
    }

    #if canImport(FoundationModels)
    /// Turns the framework's errors into something a reader can act on. The
    /// context-window case is the one worth the trouble: macOS 27 reports the
    /// real numbers, macOS 26 reports only that it happened, and both are
    /// better as a sentence about starting a new chat than as a debug string.
    @available(macOS 26.0, *)
    private static func translate(_ error: Error) -> Error {
        if #available(macOS 27.0, *) {
            if case LanguageModelError.contextSizeExceeded(let context) = error {
                return ModelError.contextExceeded(
                    tokens: context.tokenCount, limit: context.contextSize)
            }
        }
        if case LanguageModelSession.GenerationError.exceededContextWindowSize = error {
            return ModelError.contextExceeded(tokens: nil, limit: nil)
        }
        return error
    }
    #endif
}

/// Selection state for the on-device model, alongside `CloudModelStore` and
/// `ModelStore`. Holds no configuration — there is nothing to configure.
final class AppleModelStore: ObservableObject {

    static let shared = AppleModelStore()

    @Published private(set) var isSelected: Bool
    @Published private(set) var activeRequests = 0

    /// What Apple's model counted as input on the last answer it gave.
    ///
    /// The only real token figure this framework ever publishes, and only from
    /// macOS 27. It is the whole input — instructions, conversation, tool
    /// results and the question — not the prefix alone, which is exactly why
    /// the menu labels it "last request" rather than folding it into a budget
    /// it is not comparable with.
    @Published private(set) var lastInputTokens: Int?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSelected = InferenceSource.current(defaults) == .apple
    }

    /// Re-reads the shared key. Called after another store writes it, so the
    /// three selections cannot drift apart.
    func refresh() {
        let selected = InferenceSource.current(defaults) == .apple
        if isSelected != selected { isSelected = selected }
    }

    func select() {
        guard AppleFoundationModel.isAvailable else { return }
        InferenceSource.set(.apple, defaults)
        CloudModelStore.shared.refreshSelection()
        if !isSelected { isSelected = true }
    }

    /// Ignores `nil` rather than clearing: macOS 26 publishes no usage at all,
    /// and a figure that blinks out on every answer would read as a bug.
    func recordInputTokens(_ tokens: Int?) {
        guard let tokens, tokens != lastInputTokens else { return }
        lastInputTokens = tokens
    }

    func beginRequest() { activeRequests += 1 }
    func endRequest() { activeRequests = max(0, activeRequests - 1) }

    /// Read off the main actor, the way `CloudModelStore.selectedConfiguration`
    /// is, so `ChatClient` can route without hopping threads first.
    static var isSelectedForInference: Bool {
        InferenceSource.current() == .apple
    }
}

/// Whether the model has produced any prose yet in the current answer.
///
/// An actor rather than a `var` because it is read from inside a tool call,
/// which FoundationModels may run on any thread.
private actor SpokenFlag {
    private(set) var value = false
    func raise() { value = true }
}

/// Carries a main-actor delta callback into FoundationModels' tool loop.
///
/// `@unchecked Sendable` is sound here for one reason: `emit` is `@MainActor`,
/// so the wrapped closure can only ever be invoked on the actor it came from.
/// Nothing else in this type is mutable or reachable.
private final class DeltaSink: @unchecked Sendable {
    private let deliver: (String) -> Void

    init(_ deliver: @escaping (String) -> Void) { self.deliver = deliver }

    @MainActor func emit(_ text: String) { deliver(text) }
}
