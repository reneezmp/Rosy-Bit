import Combine
import Foundation

/// How much of the context window is already spent before anyone types a word.
///
/// Rosy's requests all begin with the same block: the system prompt, if one is
/// set, and the tool schemas for whichever skills are on. On a 2,048-token
/// context that block is not a rounding error — turning on every skill can take
/// a double-digit percentage of the window, and the only symptom is that long
/// conversations start forgetting their beginning sooner than expected. This
/// puts the number in the menu instead of leaving it to be inferred.
///
/// The measurement is real rather than estimated. `llama-server` renders the
/// request through the model's own chat template and tokenises the result with
/// the model's own tokeniser, so the count is what the model will actually be
/// given. Neither endpoint runs inference, so asking costs a few milliseconds.
///
/// Four renders are needed rather than two, because the tool block does not sit
/// beside the system prompt — the template folds it *into* the system message.
/// So each part is measured by difference:
///
///     template  = an empty conversation, no system prompt, no tools
///     system    = (system, no tools) − template
///     tools     = (system and tools) − (system, no tools)
///
/// which is why the three add up to the total exactly.
final class PrefixBudget: ObservableObject {

    static let shared = PrefixBudget()

    struct Measurement: Equatable {
        var total: Int
        var systemPrompt: Int
        var toolSchema: Int
        /// The chat template's own scaffolding — role markers, the opening of
        /// the assistant turn. Not something any setting controls, but without
        /// it the parts would not sum to the total and the readout would look
        /// broken rather than merely incomplete.
        var template: Int
        var contextSize: Int

        var percentOfContext: Int {
            guard contextSize > 0 else { return 0 }
            return Int((Double(total) / Double(contextSize) * 100).rounded())
        }
    }

    /// What the menu has to show. Not every runtime can be measured the same
    /// way, and pretending otherwise is how a readout starts lying.
    enum Reading: Equatable {
        /// Real tokens, from the tokeniser of the model that is loaded.
        case tokens(Measurement)
        /// Apple's on-device model, which has no tokeniser to call. Characters
        /// are free and immediate; the token figures cost three one-token
        /// generations and arrive only once the budget is actually opened.
        case onDevice(OnDevice)
        /// Nothing to report, and why.
        case unavailable(String)
    }

    struct OnDevice: Equatable {
        var systemPromptCharacters: Int
        var lastInputTokens: Int?
        var measured: AppleFoundationModel.PrefixMeasurement?
        /// True when macOS is too old to publish usage, so no measurement is
        /// possible and characters are all there will ever be.
        var canMeasure: Bool
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var isMeasuring = false

    /// What the current measurement describes. A different model, system
    /// prompt, or set of enabled skills means a different prefix, and a stale
    /// number is worse than no number.
    private var measuredKey: String?
    private var task: Task<Void, Never>?

    private init() {}

    /// Measures if anything has changed since the last one. Called when the
    /// menu opens, so it is on the same "only when someone looks" footing as
    /// every other refresh in this app.
    @MainActor
    func refresh() {
        // Only a running local llama-server can tokenise. Everything else gets
        // an exact statement of what it can say instead, computed here and now
        // — none of it needs the network.
        switch InferenceSource.current() {
        case .apple:
            // Characters and the last request's usage are free, so they land
            // immediately. Tokens are not: measuring them runs the model, and
            // that waits until someone opens the budget and asks.
            let key = onDeviceKey()
            if measuredOnDeviceKey != key {
                measuredOnDevice = nil
                measuredOnDeviceKey = nil
            }
            let onDevice = OnDevice(
                systemPromptCharacters: Config.systemPrompt?.count ?? 0,
                lastInputTokens: AppleModelStore.shared.lastInputTokens,
                measured: measuredOnDevice,
                canMeasure: canMeasureOnDevice)
            // A probe already running for this same prefix is the answer this
            // reading is waiting for. This runs on every menu open and on every
            // server event, so cancelling here would throw away three real
            // generations each time and leave nothing cached to show for them.
            return settle(.onDevice(onDevice), keepingWork: inFlightOnDeviceKey == key)
        case .cloud:
            return settle(.unavailable("Counted by the provider, not here."))
        case .local:
            guard ServerController.shared.state == .running else {
                return settle(.unavailable("Start the server to measure."))
            }
        }

        let systemPrompt = Config.systemPrompt
        let schemas = ChatClient.toolSchemas(isCloud: false)
        let contextSize = Config.contextSize
        let key = Self.key(
            systemPrompt: systemPrompt,
            schemas: schemas,
            model: ModelStore.shared.selectedName,
            contextSize: contextSize)
        guard key != measuredKey else { return }

        task?.cancel()
        isMeasuring = true
        task = Task { [weak self] in
            let measured = await Self.measure(
                systemPrompt: systemPrompt, schemas: schemas, contextSize: contextSize)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isMeasuring = false
                self.task = nil
                // A failed measurement leaves the key unset so the next menu
                // open tries again. The server may simply have been mid-restart.
                self.measuredKey = measured == nil ? nil : key
                self.reading = measured.map(Reading.tokens)
            }
        }
    }

    private var measuredOnDevice: AppleFoundationModel.PrefixMeasurement?
    private var measuredOnDeviceKey: String?
    /// The prefix a running probe is measuring, so `settle` can tell work worth
    /// keeping from work a changed selection has made pointless.
    private var inFlightOnDeviceKey: String?

    private var canMeasureOnDevice: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    private func onDeviceKey() -> String {
        Self.key(
            systemPrompt: Config.systemPrompt,
            schemas: ChatClient.toolSchemas(isCloud: false, isApple: true),
            model: "apple-on-device",
            contextSize: 0)
    }

    /// Runs the three one-token probes behind `AppleFoundationModel`.
    ///
    /// Deliberately **not** called when the menu bar opens. Every other refresh
    /// in this app is free — a file listing, a health flag, a tokeniser that
    /// runs no inference — and this one is not: it starts the model. So it is
    /// wired to the Context Budget submenu opening instead, which is a person
    /// asking for exactly this number rather than reaching past it on the way
    /// to Quit.
    @MainActor
    func measureOnDevice() {
        guard InferenceSource.current() == .apple, canMeasureOnDevice else { return }
        let key = onDeviceKey()
        guard key != measuredOnDeviceKey, !isMeasuring else { return }

        let instructions = Config.systemPrompt
        let schemas = ChatClient.toolSchemas(isCloud: false, isApple: true)
        task?.cancel()
        isMeasuring = true
        inFlightOnDeviceKey = key
        task = Task { [weak self] in
            var measured: AppleFoundationModel.PrefixMeasurement?
            if #available(macOS 27.0, *) {
                measured = await AppleFoundationModel.measurePrefix(
                    instructions: instructions, toolSchemas: schemas)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isMeasuring = false
                self.task = nil
                self.inFlightOnDeviceKey = nil
                // A failed probe leaves the key unset so opening the submenu
                // again tries once more, rather than showing nothing for ever.
                self.measuredOnDeviceKey = measured == nil ? nil : key
                self.measuredOnDevice = measured
                self.refresh()
            }
        }
    }

    /// Records a reading that needed no measuring, cancelling any that was.
    ///
    /// `keepingWork` is the exception: a probe already running for the prefix
    /// this reading describes is producing the missing half of it, so tearing
    /// it down would only make the next open pay for the same generations
    /// again.
    @MainActor
    private func settle(_ value: Reading, keepingWork: Bool = false) {
        if !keepingWork {
            task?.cancel()
            task = nil
            inFlightOnDeviceKey = nil
            isMeasuring = false
        }
        measuredKey = nil
        if reading != value { reading = value }
    }

    private static func key(
        systemPrompt: String?,
        schemas: [[String: Any]],
        model: String?,
        contextSize: Int
    ) -> String {
        let tools = (try? JSONSerialization.data(
            withJSONObject: schemas, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(schemas.count)"
        return [systemPrompt ?? "", tools, model ?? "", String(contextSize)]
            .joined(separator: "\u{0}")
    }

    private static func measure(
        systemPrompt: String?,
        schemas: [[String: Any]],
        contextSize: Int
    ) async -> Measurement? {
        async let bare = renderedTokens(systemPrompt: nil, schemas: [])
        async let withSystem = renderedTokens(systemPrompt: systemPrompt, schemas: [])
        async let withTools = renderedTokens(systemPrompt: systemPrompt, schemas: schemas)

        guard let template = await bare,
              let system = await withSystem,
              let total = await withTools else { return nil }

        // Differences, so a template that reorders or omits a part cannot
        // produce a negative line.
        return Measurement(
            total: total,
            systemPrompt: max(0, system - template),
            toolSchema: max(0, total - system),
            template: template,
            contextSize: contextSize)
    }

    /// One render plus one tokenisation. `nil` on any failure — the server may
    /// be restarting, and a missing number says so honestly.
    private static func renderedTokens(
        systemPrompt: String?,
        schemas: [[String: Any]]
    ) async -> Int? {
        // Exactly the prefix `ChatClient.performWarm` sends, including the
        // empty user turn: the measurement has to describe the request that is
        // really made, not a tidier one.
        var messages: [[String: String]] = []
        if let systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": ""])

        var payload: [String: Any] = ["messages": messages]
        if !schemas.isEmpty {
            payload["tools"] = schemas
            payload["tool_choice"] = "auto"
        }

        guard let templateURL = Config.applyTemplateURL,
              let tokenizeURL = Config.tokenizeURL,
              let rendered: String = await post(
                templateURL, payload: payload, field: "prompt"),
              // Counted as `[Any]` rather than cast to `[Int]`: JSONSerialization
              // hands back `NSNumber`s, and only the length is wanted anyway.
              let tokens: [Any] = await post(
                tokenizeURL, payload: ["content": rendered], field: "tokens")
        else { return nil }
        return tokens.count
    }

    private static func post<T>(
        _ url: URL,
        payload: [String: Any],
        field: String
    ) async -> T? {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RosyBit", forHTTPHeaderField: "X-RosyBit-Source")
        // Neither endpoint generates anything, so a slow answer means a busy
        // machine rather than a long job. Give up rather than hold the menu's
        // next refresh behind a stalled request.
        request.timeoutInterval = 20
        request.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200...299).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[field] as? T
    }
}
