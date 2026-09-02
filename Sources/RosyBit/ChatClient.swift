import Foundation

/// Talks to the endpoint the way any other client would.
///
/// Deliberately goes through the public port rather than straight to
/// llama-server, so Rosy Bit's own conversations appear in Insights alongside
/// everything else — and so this keeps working unchanged when Insights is off
/// and there is no proxy at all.
struct ChatClient {

    struct GenerationMetrics: Equatable {
        let timeToFirstToken: TimeInterval?
        let tokensPerSecond: Double?
        let totalTokens: Int?

        static let unavailable = GenerationMetrics(
            timeToFirstToken: nil, tokensPerSecond: nil, totalTokens: nil)
    }

    struct Message {
        let role: String
        let content: String

        static func system(_ content: String) -> Message { Message(role: "system", content: content) }

        /// A compact, explicitly labelled local timestamp belongs on each user
        /// turn, not beside the system prompt. The system prompt is the reusable
        /// prefix; putting a changing date there would invalidate that cache on
        /// every request. Date, minute, and a short zone give a small model enough
        /// semantic context without spending tokens on seconds or an IANA name.
        static func user(
            _ content: String,
            at date: Date = Date(),
            timeZone: TimeZone = .current
        ) -> Message {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatter.timeZone = timeZone
            let timestamp = formatter.string(from: date)
            // Follow Foundation's own short notation for the active date and
            // zone. On macOS, America/Sao_Paulo is rendered as "GMT-3". This
            // keeps Rosy aligned with the operating system rather than carrying
            // a hand-maintained regional abbreviation or invented prefix.
            let zone = timeZone.abbreviation(for: date) ?? timeZone.identifier
            return Message(
                role: "user",
                content: "[Timestamp: \(timestamp) \(zone)]\n\(content)")
        }

        static func assistant(_ content: String) -> Message { Message(role: "assistant", content: content) }
    }

    enum ChatError: LocalizedError {
        case notConfigured
        case http(Int)
        case multipleToolCalls

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "The endpoint URL could not be built."
            case .http(let status): return "The server answered with HTTP \(status)."
            case .multipleToolCalls: return "Rosy requested more than one tool at once."
            }
        }
    }

    private struct StreamResult {
        var content = ""
        var reasoningContent = ""
        var toolIDs: [Int: String] = [:]
        var toolNames: [Int: String] = [:]
        var toolArguments: [Int: String] = [:]
        var startedAt = Date()
        var firstTokenAt: Date?
        var completedAt = Date()
        var promptTokens: Int?
        var completionTokens: Int?
        var finishReason: String?
        var rawEvents = ""

        var decodeDuration: TimeInterval? {
            firstTokenAt.map { max(0, completedAt.timeIntervalSince($0)) }
        }
    }

    private struct ExecutedTool {
        let id: String
        let name: String
        let rawArguments: String
        let observation: String
        let displayedContent: String?
    }

    private struct Destination {
        let url: URL
        let model: String
        let cloud: CloudProviderConfiguration?

        var providerName: String? { cloud?.displayName }
    }

    /// The exact block shared by warming, automatic routing, and grounded
    /// follow-ups. Prefix reuse depends on this remaining byte-for-byte stable.
    private static func toolSchemas(isCloud: Bool) -> [[String: Any]] {
        SkillSettings.schemas(
            isCloud: isCloud,
            modelName: ModelStore.shared.selectedModel?.lastPathComponent)
    }

    /// Streams a completion, calling `onDelta` on the main thread for each
    /// fragment as it arrives.
    ///
    /// Returns the `Task` so the caller can cancel — which matters more here
    /// than usual, since a generation this machine has started can run for
    /// minutes and cancelling is the only way to get the cores back.
    @discardableResult
    static func send(
        messages: [Message],
        messageID: UUID? = nil,
        onDelta: @escaping (String) -> Void,
        onCompletion: @escaping (Result<GenerationMetrics, Error>) -> Void
    ) -> Task<Void, Never> {
        Task {
            let latestUserMessage = messages.last(where: { $0.role == "user" })?.content

            if let command = latestUserMessage.flatMap({ RemindersTool.explicitCommand(in: $0) }) {
                guard SkillSettings.isEnabled(.reminders) else {
                    await completeDirectly("Reminders is turned off in Skills.", onDelta: onDelta, onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try await RemindersTool.execute(command)
                    if Task.isCancelled { return }
                    await completeDirectly(response, onDelta: onDelta, onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let command = latestUserMessage.flatMap(AppsFinderTool.explicitCommand) {
                guard SkillSettings.isEnabled(.appsFinder) else {
                    await completeDirectly("Apps & Finder is turned off in Skills.", onDelta: onDelta, onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try await AppsFinderTool.execute(command)
                    if Task.isCancelled { return }
                    await completeDirectly(response, onDelta: onDelta, onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let query = latestUserMessage.flatMap(FileSearchTool.explicitFilenameQuery) {
                guard SkillSettings.isEnabled(.fileSearch) else {
                    await completeDirectly("File Search is turned off in Skills.", onDelta: onDelta, onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try FileSearchTool.result(for: query, filenamesOnly: true)
                    if Task.isCancelled { return }
                    await completeDirectly(response, onDelta: onDelta, onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let query = latestUserMessage.flatMap(FileSearchTool.explicitQuery) {
                guard SkillSettings.isEnabled(.fileSearch) else {
                    await completeDirectly("File Search is turned off in Skills.", onDelta: onDelta, onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try FileSearchTool.result(for: query)
                    if Task.isCancelled { return }
                    await completeDirectly(response, onDelta: onDelta, onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let timerCommand = latestUserMessage.flatMap(TimerTool.explicitCommand) {
                guard SkillSettings.isEnabled(.timers) else {
                    await completeDirectly(
                        "Timers are turned off in Skills.",
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try await TimerTool.execute(timerCommand)
                    if Task.isCancelled { return }
                    await completeDirectly(
                        response,
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let calculatorQuery = latestUserMessage.flatMap(CalculatorTool.explicitQuery) {
                guard SkillSettings.isEnabled(.calculatorUnits) else {
                    await completeDirectly(
                        "Calculator & Units is turned off in Skills.",
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try CalculatorTool.result(for: calculatorQuery)
                    if Task.isCancelled { return }
                    await completeDirectly(
                        response,
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let metric = latestUserMessage.flatMap(SystemStatusTool.explicitMetric) {
                guard SkillSettings.isEnabled(.batterySystem) else {
                    await completeDirectly(
                        "Battery & System is turned off in Skills.",
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try SystemStatusTool.result(for: metric)
                    if Task.isCancelled { return }
                    await completeDirectly(
                        response,
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            if let volumeCommand = latestUserMessage.flatMap(VolumeTool.explicitCommand) {
                guard SkillSettings.isEnabled(.volumeControl) else {
                    await completeDirectly(
                        "Volume Control is turned off in Skills.",
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                    return
                }
                do {
                    let response = try VolumeTool.execute(volumeCommand)
                    if Task.isCancelled { return }
                    await completeDirectly(
                        response,
                        onDelta: onDelta,
                        onCompletion: onCompletion)
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { onCompletion(.failure(error)) }
                }
                return
            }

            let cloudSelected = await MainActor.run {
                CloudModelStore.shared.isCloudSelected
            }
            let cloud = CloudModelStore.selectedConfiguration
            if !cloudSelected {
                // Costs the caller nothing. The prefix has to be prefilled
                // either way, so waiting for a local warm already doing it is
                // the same work in a different order.
                await warmInFlight()
            }
            if Task.isCancelled { return }

            do {
                guard !cloudSelected || cloud != nil else {
                    throw CloudProviderError.notConfigured
                }
                let destination = try destination(cloud: cloud)
                if cloud != nil {
                    await MainActor.run { CloudModelStore.shared.beginRequest() }
                }
                defer {
                    if cloud != nil {
                        Task { @MainActor in CloudModelStore.shared.endRequest() }
                    }
                }
                let request = try request(
                    for: destination, messageID: messageID)

                let schemas = toolSchemas(isCloud: cloud != nil)
                let dictionaryEnabled = schemas.contains { schema in
                    guard let function = schema["function"] as? [String: Any] else { return false }
                    return function["name"] as? String == DictionaryTool.name
                }
                let routedDictionaryTerm = dictionaryEnabled
                    ? messages.last(where: { $0.role == "user" }).flatMap {
                        DictionaryTool.explicitLookupTerm(in: $0.content)
                    }
                    : nil

                let wireMessages: [[String: Any]] = messages.map {
                    ["role": $0.role, "content": $0.content]
                }
                var payload = requestPayload(
                    destination: destination,
                    messages: wireMessages,
                    tools: schemas,
                    toolChoice: schemas.isEmpty ? nil : "auto")
                // Off by default: `id_slot` is not honoured on this endpoint.
                // See Config.internalSlot. Kept as a setting in case upstream
                // ever starts reading it.
                let slot = Config.internalSlot
                if cloud == nil, slot >= 0 {
                    payload["id_slot"] = slot
                }
                var streams: [StreamResult] = []
                var executed: ExecutedTool?
                var routingReasoning: String?

                if let routedDictionaryTerm {
                    // An explicit definition request needs no probabilistic
                    // routing pass. Execute the same allowlisted tool locally,
                    // then give the model only the grounded presentation pass.
                    let call = DictionaryTool.routedCall(term: routedDictionaryTerm)
                    executed = try await executeTool(
                        id: call.id,
                        name: DictionaryTool.name,
                        arguments: call.rawArguments)
                } else {
                    let first = try await stream(
                        payload: payload,
                        request: request,
                        providerName: destination.providerName,
                        messageID: messageID,
                        onDelta: onDelta)
                    streams.append(first)
                    routingReasoning = first.reasoningContent.isEmpty
                        ? nil : first.reasoningContent
                    if !first.toolNames.isEmpty {
                        guard !schemas.isEmpty else {
                            throw DictionaryTool.ToolError.unavailableForModel
                        }
                        guard first.toolNames.count == 1,
                              let index = first.toolNames.keys.first else {
                            throw ChatError.multipleToolCalls
                        }
                        executed = try await executeTool(
                            id: first.toolIDs[index],
                            name: first.toolNames[index],
                            arguments: first.toolArguments[index] ?? "")
                    }
                }

                if let executed {
                    if let displayedContent = executed.displayedContent {
                        await MainActor.run { onDelta(displayedContent) }
                    }

                    var followUpMessages: [[String: Any]] = messages.map {
                        ["role": $0.role, "content": $0.content]
                    }
                    var assistantToolCall: [String: Any] = [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [[
                            "id": executed.id,
                            "type": "function",
                            "function": [
                                "name": executed.name,
                                "arguments": executed.rawArguments
                            ]
                        ]]
                    ]
                    if let routingReasoning {
                        assistantToolCall["reasoning_content"] = routingReasoning
                    }
                    followUpMessages.append(assistantToolCall)
                    followUpMessages.append([
                        "role": "tool",
                        "tool_call_id": executed.id,
                        "content": executed.observation
                    ])

                    let followUp = requestPayload(
                        destination: destination,
                        messages: followUpMessages,
                        tools: schemas,
                        toolChoice: "none")
                    let final = try await stream(
                        payload: followUp,
                        request: request,
                        providerName: destination.providerName,
                        messageID: messageID,
                        onDelta: onDelta)
                    streams.append(final)
                    if !final.toolNames.isEmpty || !final.toolArguments.isEmpty {
                        // One retrieval and one grounded answer is the whole
                        // loop. Even if a runtime ignores `tool_choice: none`,
                        // Rosy Bit never executes a second request.
                        throw ChatError.multipleToolCalls
                    }
                }

                if Task.isCancelled { return }
                let metrics = metrics(for: streams)
                await MainActor.run { onCompletion(.success(metrics)) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { onCompletion(.failure(error)) }
            }
        }
    }

    @MainActor
    private static func completeDirectly(
        _ response: String,
        onDelta: @escaping (String) -> Void,
        onCompletion: @escaping (Result<GenerationMetrics, Error>) -> Void
    ) {
        guard !Task.isCancelled else { return }
        onDelta(response)
        onCompletion(.success(.unavailable))
    }

    private static func destination(
        cloud: CloudProviderConfiguration?
    ) throws -> Destination {
        if let cloud {
            let validated = try cloud.validated()
            guard let url = URL(string: validated.endpoint) else {
                throw CloudProviderError.invalidEndpoint
            }
            return Destination(url: url, model: validated.model, cloud: validated)
        }
        guard let url = Config.chatCompletionsURL else { throw ChatError.notConfigured }
        return Destination(url: url, model: "rosybit", cloud: nil)
    }

    private static func request(
        for destination: Destination,
        messageID: UUID?
    ) throws -> URLRequest {
        var request = URLRequest(url: destination.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        if let cloud = destination.cloud {
            if let key = CloudCredentialStore.load(), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            } else if cloud.kind == .deepSeek {
                throw CloudProviderError.missingAPIKey
            }
            request.timeoutInterval = 300
        } else {
            // Lets Insights tell Rosy Bit's own traffic from a client's.
            request.setValue("RosyBit", forHTTPHeaderField: "X-RosyBit-Source")
            if let messageID {
                request.setValue(
                    messageID.uuidString,
                    forHTTPHeaderField: "X-RosyBit-Message-ID")
            }
            // Generation on Rosy is measured in minutes, not seconds.
            request.timeoutInterval = 900
        }
        return request
    }

    private static func requestPayload(
        destination: Destination,
        messages: [[String: Any]],
        tools: [[String: Any]],
        toolChoice: String?
    ) -> [String: Any] {
        if let cloud = destination.cloud {
            return CloudRequestBuilder.payload(
                configuration: cloud,
                messages: messages,
                tools: tools.isEmpty ? nil : tools,
                toolChoice: toolChoice)
        }

        var payload: [String: Any] = [
            "model": destination.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools
            if let toolChoice { payload["tool_choice"] = toolChoice }
        }
        return payload
    }

    private static func executeTool(
        id: String?,
        name: String?,
        arguments: String
    ) async throws -> ExecutedTool {
        switch name {
        case DictionaryTool.name:
            guard SkillSettings.isEnabled(.dictionary) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try DictionaryTool.parse(
                id: id, name: name, arguments: arguments)
            let definition = DictionaryTool.lookup(call.term)
            return ExecutedTool(
                id: call.id,
                name: DictionaryTool.name,
                rawArguments: call.rawArguments,
                observation: DictionaryTool.observation(
                    term: call.term, definition: definition),
                displayedContent: DictionaryTool.displayedEntry(
                    term: call.term, definition: definition))
        case VolumeTool.name:
            guard SkillSettings.isEnabled(.volumeControl) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try VolumeTool.parse(id: id, arguments: arguments)
            let percentage = try VolumeTool.currentOutputPercentage()
            return ExecutedTool(
                id: call.id,
                name: VolumeTool.name,
                rawArguments: call.rawArguments,
                observation: VolumeTool.observation(percentage: percentage),
                displayedContent: nil)
        case CalculatorTool.name:
            guard SkillSettings.isEnabled(.calculatorUnits) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try CalculatorTool.parse(id: id, arguments: arguments)
            let result = try CalculatorTool.result(for: call.query)
            return ExecutedTool(
                id: call.id,
                name: CalculatorTool.name,
                rawArguments: call.rawArguments,
                observation: CalculatorTool.observation(query: call.query, result: result),
                displayedContent: nil)
        case TimerTool.name:
            guard SkillSettings.isEnabled(.timers) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try TimerTool.parse(id: id, arguments: arguments)
            return ExecutedTool(
                id: call.id,
                name: TimerTool.name,
                rawArguments: call.rawArguments,
                observation: TimerTool.observation(),
                displayedContent: nil)
        case SystemStatusTool.name:
            guard SkillSettings.isEnabled(.batterySystem) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try SystemStatusTool.parse(id: id, arguments: arguments)
            let result = try SystemStatusTool.result(for: call.metric)
            return ExecutedTool(
                id: call.id,
                name: SystemStatusTool.name,
                rawArguments: call.rawArguments,
                observation: SystemStatusTool.observation(metric: call.metric, result: result),
                displayedContent: nil)
        case AppsFinderTool.name:
            guard SkillSettings.isEnabled(.appsFinder) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try AppsFinderTool.parse(id: id, arguments: arguments)
            return ExecutedTool(
                id: call.id,
                name: AppsFinderTool.name,
                rawArguments: call.rawArguments,
                observation: AppsFinderTool.observation(query: call.query),
                displayedContent: nil)
        case FileSearchTool.name:
            guard SkillSettings.isEnabled(.fileSearch) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try FileSearchTool.parse(id: id, arguments: arguments)
            let result = try FileSearchTool.result(for: call.query)
            return ExecutedTool(
                id: call.id,
                name: FileSearchTool.name,
                rawArguments: call.rawArguments,
                observation: FileSearchTool.observation(query: call.query, result: result),
                displayedContent: nil)
        case RemindersTool.name:
            guard SkillSettings.isEnabled(.reminders) else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let call = try RemindersTool.parse(id: id, arguments: arguments)
            return ExecutedTool(
                id: call.id,
                name: RemindersTool.name,
                rawArguments: call.rawArguments,
                observation: try await RemindersTool.observation(),
                displayedContent: nil)
        case ModelLedActionTool.volumeName,
             ModelLedActionTool.timerName,
             ModelLedActionTool.appsFinderName,
             ModelLedActionTool.remindersName:
            guard SkillSettings.routingMode() == .modelLed, let name else {
                throw DictionaryTool.ToolError.unsupportedCall
            }
            let result = try await ModelLedActionTool.execute(
                id: id, name: name, arguments: arguments)
            return ExecutedTool(
                id: result.id,
                name: result.name,
                rawArguments: result.rawArguments,
                observation: result.observation,
                displayedContent: nil)
        default:
            throw DictionaryTool.ToolError.unsupportedCall
        }
    }

    private static func stream(
        payload: [String: Any],
        request template: URLRequest,
        providerName: String?,
        messageID: UUID?,
        onDelta: @escaping (String) -> Void
    ) async throws -> StreamResult {
        var request = template
        let body = providerName == nil
            ? try JSONSerialization.data(withJSONObject: payload)
            : try CloudRequestBuilder.encoded(payload)
        request.httpBody = body

        let startedAt = Date()
        var insightRecord: RequestRecord?
        if providerName != nil, Config.insightsEnabled,
           let bodyText = String(data: body, encoding: .utf8),
           let url = request.url {
            insightRecord = RequestRecord.directCloudRequest(
                url: url,
                body: bodyText,
                chatMessageID: messageID,
                startedAt: startedAt)
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            insightRecord?.statusCode = status
            if let status, !(200...299).contains(status) {
                var errorBody = ""
                for try await line in bytes.lines {
                    if !errorBody.isEmpty { errorBody += "\n" }
                    errorBody += line
                }
                if providerName != nil {
                    insightRecord?.responseBody = BodySanitiser.sanitise(errorBody)
                    insightRecord?.responseText = BodySanitiser.sanitise(
                        cloudErrorMessage(errorBody))
                    throw CloudProviderError.http(
                        provider: providerName ?? "Cloud provider",
                        status: status,
                        message: cloudErrorMessage(errorBody))
                }
                throw ChatError.http(status)
            }

            var result = StreamResult(startedAt: startedAt, completedAt: startedAt)
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                if providerName != nil {
                    if !result.rawEvents.isEmpty { result.rawEvents += "\n" }
                    result.rawEvents += line
                }
                guard line.hasPrefix("data:") else { continue }

                let event = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if event == "[DONE]" { break }
                guard let data = event.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let usage = object["usage"] as? [String: Any] {
                    result.promptTokens = usage["prompt_tokens"] as? Int
                        ?? result.promptTokens
                    result.completionTokens = usage["completion_tokens"] as? Int
                        ?? result.completionTokens
                }
                guard let choices = object["choices"] as? [[String: Any]],
                      let first = choices.first else { continue }
                if let reason = first["finish_reason"] as? String {
                    result.finishReason = reason
                }
                guard let delta = first["delta"] as? [String: Any] else { continue }

                if let content = delta["content"] as? String, !content.isEmpty {
                    if result.firstTokenAt == nil { result.firstTokenAt = Date() }
                    result.content += content
                    await MainActor.run { onDelta(content) }
                }

                if let reasoning = delta["reasoning_content"] as? String,
                   !reasoning.isEmpty {
                    result.reasoningContent += reasoning
                }

                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    if !calls.isEmpty, result.firstTokenAt == nil { result.firstTokenAt = Date() }
                    for call in calls {
                        let index = call["index"] as? Int ?? 0
                        if let id = call["id"] as? String { result.toolIDs[index] = id }
                        guard let function = call["function"] as? [String: Any] else { continue }
                        if let name = function["name"] as? String {
                            result.toolNames[index] = name
                        }
                        if let fragment = function["arguments"] as? String {
                            result.toolArguments[index, default: ""] += fragment
                        }
                    }
                }
            }
            result.completedAt = Date()
            if insightRecord != nil {
                insightRecord?.durationMs = result.completedAt.timeIntervalSince(startedAt) * 1000
                insightRecord?.promptTokens = result.promptTokens
                insightRecord?.completionTokens = result.completionTokens
                insightRecord?.finishReason = result.finishReason
                insightRecord?.responseBody = BodySanitiser.sanitise(result.rawEvents)
                insightRecord?.responseText = BodySanitiser.sanitise(
                    insightResponseText(for: result))
                await recordCloudInsight(insightRecord)
            }
            return result
        } catch {
            if insightRecord != nil {
                insightRecord?.durationMs = Date().timeIntervalSince(startedAt) * 1000
                if insightRecord?.responseText == nil {
                    insightRecord?.responseText = BodySanitiser.sanitise(
                        error is CancellationError ? "Cancelled." : error.localizedDescription)
                }
                if insightRecord?.statusCode == nil { insightRecord?.parseFailed = true }
                await recordCloudInsight(insightRecord)
            }
            throw error
        }
    }

    @MainActor
    private static func recordCloudInsight(_ record: RequestRecord?) {
        guard let record else { return }
        InsightsStore.shared.record(record)
    }

    private static func insightResponseText(for result: StreamResult) -> String? {
        if !result.content.isEmpty { return result.content }
        guard !result.toolNames.isEmpty else { return nil }
        return result.toolNames.keys.sorted().map { index in
            let name = result.toolNames[index] ?? "tool"
            let arguments = result.toolArguments[index] ?? ""
            return arguments.isEmpty ? "\(name)()" : "\(name)(\(arguments))"
        }.joined(separator: "\n")
    }

    private static func cloudErrorMessage(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return trimmed }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String ?? trimmed
    }

    private static func metrics(for streams: [StreamResult]) -> GenerationMetrics {
        guard let first = streams.first else { return .unavailable }
        let ttft = first.firstTokenAt.map { $0.timeIntervalSince(first.startedAt) }
        let tokenCounts = streams.compactMap(\.completionTokens)
        let totalTokens = tokenCounts.count == streams.count
            ? tokenCounts.reduce(0, +)
            : nil
        let decodeSeconds = streams.compactMap(\.decodeDuration).reduce(0, +)
        let speed = totalTokens.flatMap { tokens in
            decodeSeconds > 0 ? Double(tokens) / decodeSeconds : nil
        }
        return GenerationMetrics(
            timeToFirstToken: ttft,
            tokensPerSecond: speed,
            totalTokens: totalTokens)
    }

    // MARK: - Prefix warming

    /// llama-server caches the longest common prefix per slot, so the system
    /// prompt — and, once tools are enabled, the tool block with them — is
    /// prefilled once and reused. Nothing warms it until a first question pays
    /// for it, which on Rosy is the difference between an 18 second answer and
    /// a 4 second one.
    ///
    /// A `max_tokens: 0` request prefills that prefix and generates nothing.
    /// Measured on the M4: without it a question prefills 203 tokens, with it
    /// 15 — only the user's own words. This is certain work done early rather
    /// than speculative work done hopefully, which is the line that separates
    /// it from the background polling this project refuses to do. Every request
    /// that will ever arrive needs this prefix.
    @MainActor private static var warmTask: Task<Void, Never>?

    /// Whether a warm is running, for a hint in the ask bar. The field stays
    /// typeable regardless: typing happens here and prefilling happens in
    /// llama-server, and they do not contend.
    @MainActor static var isWarming: Bool { warmTask != nil }

    /// Starts a warm, replacing any already running — being called again means
    /// the prefix itself changed, so the one in flight is warming the wrong
    /// thing.
    @MainActor static func warmPrefix() {
        warmTask?.cancel()
        warmTask = Task {
            defer { warmTask = nil }
            await performWarm()
        }
    }

    /// Awaits any warm in flight. Returns immediately when there is none, which
    /// is the overwhelmingly common case — the warm finishes at login and the
    /// first question usually arrives hours later.
    @MainActor static func warmInFlight() async {
        await warmTask?.value
    }

    private static func performWarm() async {
        // Prefix warming belongs to llama-server. A cloud profile selected
        // while a local warm is queued must not produce an uninvited local
        // request after the switch.
        guard CloudModelStore.selectedConfiguration == nil else { return }
        guard let url = Config.chatCompletionsURL else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RosyBit", forHTTPHeaderField: "X-RosyBit-Source")
        // Long enough for a cold model on two cores, far short of a generation:
        // nothing is being generated here.
        request.timeoutInterval = 180

        // Exactly the prefix a real question will present, and no more. The
        // empty user turn is deliberate — it reproduces the opening of the user
        // block, so the cached prefix runs right up to the first real token.
        var messages: [[String: String]] = []
        if let systemPrompt = Config.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": ""])

        var payload: [String: Any] = [
            "model": "rosybit",
            "stream": false,
            "max_tokens": 0,
            "messages": messages,
        ]
        let schemas = toolSchemas(isCloud: false)
        if !schemas.isEmpty {
            payload["tools"] = schemas
            payload["tool_choice"] = "auto"
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body

        // A failed warm is not worth reporting. It costs the next question the
        // prefill it would have paid anyway, and nothing else.
        _ = try? await URLSession.shared.data(for: request)
    }
}
