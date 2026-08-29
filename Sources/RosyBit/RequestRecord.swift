import Foundation

/// One message from the request's `messages` array, pulled out at capture time.
struct PromptMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

/// One request/response pair as seen by the proxy.
struct RequestRecord: Identifiable {

    let id = UUID()
    let startedAt: Date

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
