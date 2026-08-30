import Foundation

/// Talks to the endpoint the way any other client would.
///
/// Deliberately goes through the public port rather than straight to
/// llama-server, so Rosy Bit's own conversations appear in Insights alongside
/// everything else — and so this keeps working unchanged when Insights is off
/// and there is no proxy at all.
struct ChatClient {

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
            let zone: String
            if timeZone.identifier == "America/Sao_Paulo",
               timeZone.secondsFromGMT(for: date) == -3 * 60 * 60 {
                // Foundation renders this as "GMT-3"; BRT is shorter and gives
                // the model the more useful human name Renée expects.
                zone = "BRT"
            } else {
                zone = timeZone.abbreviation(for: date) ?? timeZone.identifier
            }
            return Message(
                role: "user",
                content: "[Timestamp: \(timestamp) \(zone)]\n\(content)")
        }

        static func assistant(_ content: String) -> Message { Message(role: "assistant", content: content) }
    }

    enum ChatError: LocalizedError {
        case notConfigured
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "The endpoint URL could not be built."
            case .http(let status): return "The server answered with HTTP \(status)."
            }
        }
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
        onDelta: @escaping (String) -> Void,
        onCompletion: @escaping (Result<Void, Error>) -> Void
    ) -> Task<Void, Never> {
        Task {
            // Costs the caller nothing. The prefix has to be prefilled either
            // way, so waiting for a warm already doing it is the same work in a
            // different order — and it keeps this question on the slot the warm
            // just populated rather than racing onto an empty one.
            await warmInFlight()
            if Task.isCancelled { return }

            do {
                guard let url = Config.chatCompletionsURL else { throw ChatError.notConfigured }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Lets Insights tell Rosy Bit's own traffic from a client's.
                request.setValue("RosyBit", forHTTPHeaderField: "X-RosyBit-Source")
                // Generation here is measured in minutes, not seconds.
                request.timeoutInterval = 900

                var payload: [String: Any] = [
                    "model": "rosybit",
                    "stream": true,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] },
                ]
                // Off by default: `id_slot` is not honoured on this endpoint.
                // See Config.internalSlot. Kept as a setting in case upstream
                // ever starts reading it.
                let slot = Config.internalSlot
                if slot >= 0 {
                    payload["id_slot"] = slot
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    throw ChatError.http(status)
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }

                    let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }

                    guard let data = payload.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = object["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String,
                          !content.isEmpty else { continue }

                    await MainActor.run { onDelta(content) }
                }

                if Task.isCancelled { return }
                await MainActor.run { onCompletion(.success(())) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { onCompletion(.failure(error)) }
            }
        }
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

        let payload: [String: Any] = [
            "model": "rosybit",
            "stream": false,
            "max_tokens": 0,
            "messages": messages,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body

        // A failed warm is not worth reporting. It costs the next question the
        // prefill it would have paid anyway, and nothing else.
        _ = try? await URLSession.shared.data(for: request)
    }
}
