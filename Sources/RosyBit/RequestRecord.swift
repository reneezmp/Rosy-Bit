import Foundation

/// One message from the request's `messages` array, pulled out at capture time.
struct PromptMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

/// One tool the model asked for during a request.
///
/// First-class rather than left inside the raw response body, because the
/// Response tab shows the assembled text when there is any — so a turn that
/// both spoke and called a tool would otherwise hide the call completely. That
/// mattered least on the proxy path, where the raw body is at least there to
/// read, and most on the on-device path, where the framework runs the loop out
/// of Rosy's sight and this is the only record that it happened.
struct ToolCallRecord: Identifiable {
    let id = UUID()
    let name: String
    let arguments: String
    /// What Rosy handed back. Only the on-device path can supply this; the
    /// proxy sees the reply on a later request, not this one.
    let observation: String?
}

/// One request/response pair as seen by the proxy.
struct RequestRecord: Identifiable {

    let id = UUID()
    let startedAt: Date
    /// Stable UI turn that caused this request. Rosy Bit adds it as a private
    /// header; ordinary OpenAI-compatible clients simply leave it nil.
    var chatMessageID: UUID?

    var method: String
    var path: String

    var statusCode: Int?
    var durationMs: Double?

    /// Bodies, already redacted and truncated. `responseText` is the assistant's
    /// message reassembled from the stream; `responseBody` is what came over the
    /// wire.
    var requestBody: String?
    var responseBody: String?
    var responseText: String?

    /// Extracted from the body *before* it was truncated. Parsing the stored
    /// `requestBody` instead would fail on exactly the long transcripts this is
    /// for, since truncation splices a marker into the middle of the JSON.
    var promptMessages: [PromptMessage] = []

    /// Tool calls the model made during this request, in the order it made them.
    var toolCalls: [ToolCallRecord] = []

    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var temperature: Double?
    var maxTokens: Int?
    var finishReason: String?
    var streamed = false

    /// Set when the parser lost the thread. The request still went through —
    /// forwarding never depends on parsing — but this record is incomplete.
    var parseFailed = false

    init(startedAt: Date = Date(), method: String, path: String) {
        self.startedAt = startedAt
        self.method = method
        self.path = path
    }

    var tokensPerSecond: Double? {
        guard let completionTokens, let durationMs, durationMs > 0 else { return nil }
        return Double(completionTokens) / (durationMs / 1000)
    }

    var isChatCompletion: Bool { path.hasSuffix("/chat/completions") }

    /// Pulls the messages out of a *whole* request body. Each message is
    /// truncated on its own, so a long transcript clips its own content instead
    /// of destroying the JSON everything else is read from.
    static func extractMessages(fromWholeBody body: String) -> [PromptMessage] {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return [] }

        return messages.compactMap { message in
            guard let role = message["role"] as? String else { return nil }

            // Content is usually a string, but the OpenAI schema also allows an
            // array of typed parts; pull the text out of those.
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                text = ""
            }
            return PromptMessage(
                role: role, content: BodySanitiser.sanitise(text) ?? "")
        }
    }

    /// Captures the common OpenAI-compatible request fields from a complete
    /// JSON body. Both the loopback proxy and Rosy's direct cloud client use
    /// this path, so Insights does not become two subtly different products.
    mutating func applyChatRequestBody(_ wholeBody: String) {
        promptMessages = Self.extractMessages(fromWholeBody: wholeBody)
        requestBody = BodySanitiser.sanitise(wholeBody)

        guard let data = wholeBody.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        model = object["model"] as? String
        temperature = object["temperature"] as? Double
        maxTokens = (object["max_tokens"] ?? object["max_completion_tokens"]) as? Int
        streamed = (object["stream"] as? Bool) ?? false
    }

    /// Starts a memory-only Insights record for a request that goes directly
    /// to a cloud provider instead of crossing Rosy's recording proxy. The
    /// Authorization header is deliberately not accepted here: secrets never
    /// enter the record in the first place.
    static func directCloudRequest(
        url: URL,
        body: String,
        chatMessageID: UUID?,
        startedAt: Date = Date()
    ) -> RequestRecord {
        let host = url.host.map { "\($0)" } ?? "cloud"
        var record = RequestRecord(
            startedAt: startedAt,
            method: "POST",
            path: host + url.path)
        record.chatMessageID = chatMessageID
        record.applyChatRequestBody(body)
        return record
    }
}

extension RequestRecord {

    /// Starts a memory-only Insights record for a call that never becomes a
    /// request.
    ///
    /// FoundationModels is in-process: there is no proxy to see it, no wire
    /// format to capture, and no status line. Left alone it would simply be
    /// missing from Insights, which would make Insights two products — the
    /// exact thing `applyChatRequestBody` exists to prevent. So the call is
    /// described in the same OpenAI-shaped vocabulary everything else uses,
    /// and the body carries a `transport` field saying plainly that it was
    /// never sent anywhere.
    ///
    /// `method` and `path` say what this is rather than dressing it as HTTP.
    /// The status code is the one concession: 200 and 500 are how this record
    /// says "finished" and "failed", because the badge reads an integer and
    /// leaving it empty renders a completed call as still in flight.
    static func onDeviceRequest(
        body: String,
        chatMessageID: UUID?,
        startedAt: Date = Date()
    ) -> RequestRecord {
        var record = RequestRecord(
            startedAt: startedAt,
            method: "CALL",
            path: "apple-intelligence/on-device")
        record.chatMessageID = chatMessageID
        record.applyChatRequestBody(body)
        return record
    }
}

/// Keeps bodies safe to hold and safe to show.
enum BodySanitiser {

    /// Bigger than this and the middle is dropped. A whole transcript is not
    /// useful to read in a detail pane and it is a lot to hold 200 of.
    static let maxBodyCharacters = 20_000

    /// Defence in depth. Nothing in this app sends an API key upstream today,
    /// but a client may put one in a header or body, and a proxy that records
    /// everything should not be the thing that writes it down.
    private static let credentialPatterns: [String] = [
        #"(?i)(authorization"?\s*[:=]\s*"?\s*bearer\s+)[A-Za-z0-9._\-]+"#,
        #"(?i)("api[_-]?key"\s*:\s*")[^"]+"#,
        #"(?i)("access[_-]?token"\s*:\s*")[^"]+"#,
        #"(?i)(x-api-key"?\s*[:=]\s*"?)[A-Za-z0-9._\-]+"#,
    ]

    private static let compiled: [NSRegularExpression] = credentialPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    static func sanitise(_ body: String?) -> String? {
        guard let body else { return nil }
        return truncate(redact(body))
    }

    static func redact(_ body: String) -> String {
        var result = body
        for regex in compiled {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "$1<redacted>")
        }
        return result
    }

    static func truncate(_ body: String) -> String {
        guard body.count > maxBodyCharacters else { return body }
        // Keep both ends: the head carries the system prompt, the tail carries
        // whatever was actually asked. Say how much went missing so a clipped
        // body is obviously clipped.
        let keep = maxBodyCharacters / 2
        let head = String(body.prefix(keep))
        let tail = String(body.suffix(keep))
        let dropped = body.count - (keep * 2)
        return "\(head)\n\n… [\(dropped) characters omitted] …\n\n\(tail)"
    }
}
