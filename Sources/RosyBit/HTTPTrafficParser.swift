import Foundation

/// Watches the bytes flowing through the proxy and reconstructs what was asked
/// and what came back.
///
/// This is strictly an observer. The proxy forwards every byte regardless of
/// what happens here, so a parsing bug produces a bad record, never a broken
/// request. When the parser cannot make sense of a connection it gives up on
/// that connection entirely and lets the bytes keep flowing.
///
/// One instance per TCP connection. HTTP/1.1 keep-alive means a connection
/// carries a sequence of request/response pairs, which are matched up in order.
/// Only ever touched from its connection's queue — the same queue that does the
/// forwarding, which is why the scanning below is careful not to rescan.
final class HTTPTrafficParser {

    /// Called when a response completes and the record is final.
    var onRecord: ((RequestRecord) -> Void)?

    private var requestBuffer = Data()
    private var responseBuffer = Data()

    /// How far each buffer has already been searched for a header terminator,
    /// so a partial head is not rescanned from the start on every packet.
    private var requestScanned = 0
    private var responseScanned = 0

    /// Requests seen but not yet answered, oldest first.
    private var pending: [RequestRecord] = []
    private var startTimes: [Date] = []

    /// Once lost, stay lost: a desynchronised parser invents records.
    private var abandoned = false

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    /// A single head or body larger than this means something is wrong, or the
    /// traffic is not worth holding. Either way, stop rather than grow forever.
    private static let maxBufferBytes = 8 * 1024 * 1024

    // MARK: - Client → server

    func consumeRequest(_ data: Data) {
        guard !abandoned else { return }
        requestBuffer.append(data)
        guard requestBuffer.count <= Self.maxBufferBytes else { return abandon() }

        while true {
            guard let headerEnd = nextHeaderEnd(in: requestBuffer, scanned: &requestScanned) else {
                return
            }

            let headData = requestBuffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let head = String(data: headData, encoding: .utf8),
                  let requestLine = head.components(separatedBy: "\r\n").first else {
                return abandon()
            }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return abandon() }

            let headers = Self.headers(from: head.components(separatedBy: "\r\n").dropFirst())
            let bodyStart = headerEnd.upperBound
            let available = requestBuffer.subdata(in: bodyStart..<requestBuffer.endIndex)
            let bodyResult: (body: Data, consumed: Int)

            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let dechunked = Self.dechunk(available) else { return }
                bodyResult = dechunked
            } else {
                let contentLength = Int(headers["content-length"] ?? "") ?? 0
                guard contentLength >= 0 else { return abandon() }
                guard available.count >= contentLength else { return }  // wait
                bodyResult = (available.subdata(in: 0..<contentLength), contentLength)
            }

            var record = RequestRecord(method: parts[0], path: parts[1])
            if !bodyResult.body.isEmpty {
                if let whole = String(data: bodyResult.body, encoding: .utf8) {
                    // Extract structure from the whole body first; truncation
                    // afterwards would leave JSON that cannot be parsed.
                    record.promptMessages = RequestRecord.extractMessages(fromWholeBody: whole)
                    applyRequestParameters(from: whole, to: &record)
                    record.requestBody = BodySanitiser.sanitise(whole)
                }
            }

            pending.append(record)
            startTimes.append(Date())
            consume(&requestBuffer, upTo: bodyStart + bodyResult.consumed, scanned: &requestScanned)
        }
    }

    private func applyRequestParameters(from body: String, to record: inout RequestRecord) {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        record.model = object["model"] as? String
        record.temperature = object["temperature"] as? Double
        record.maxTokens = (object["max_tokens"] ?? object["max_completion_tokens"]) as? Int
        record.streamed = (object["stream"] as? Bool) ?? false
    }

    // MARK: - Server → client

    func consumeResponse(_ data: Data) {
        guard !abandoned else { return }
        responseBuffer.append(data)
        guard responseBuffer.count <= Self.maxBufferBytes else { return abandon() }

        while true {
            guard let headerEnd = nextHeaderEnd(in: responseBuffer, scanned: &responseScanned) else {
                return
            }

            let headData = responseBuffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let head = String(data: headData, encoding: .utf8),
                  let statusLine = head.components(separatedBy: "\r\n").first else {
                return abandon()
            }
            let statusParts = statusLine.split(separator: " ").map(String.init)
            guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
                return abandon()
            }

            let headers = Self.headers(from: head.components(separatedBy: "\r\n").dropFirst())
            let bodyStart = headerEnd.upperBound

            // A 1xx is an interim reply that does not answer anything and never
            // carries a body. `Expect: 100-continue` is routine for a POST body
            // over about 1 KB — which is every real prompt — so treating one as
            // a response would consume the pending request and desynchronise
            // the whole connection.
            if (100..<200).contains(status) {
                consume(&responseBuffer, upTo: bodyStart, scanned: &responseScanned)
                continue
            }

            // These are final responses with no body. HEAD may still report the
            // Content-Length a corresponding GET would have sent, so it must be
            // decided from the pending request rather than from the headers.
            let answersHead = pending.first?.method.caseInsensitiveCompare("HEAD") == .orderedSame
            if status == 204 || status == 304 || answersHead {
                finish(status: status, body: nil, contentType: headers["content-type"])
                consume(&responseBuffer, upTo: bodyStart, scanned: &responseScanned)
                continue
            }

            let available = responseBuffer.subdata(in: bodyStart..<responseBuffer.endIndex)
            let bodyResult: (body: Data, consumed: Int)?

            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                bodyResult = Self.dechunk(available)
            } else if let length = Int(headers["content-length"] ?? "") {
                guard length >= 0 else { return abandon() }
                guard available.count >= length else { return }  // wait for more
                bodyResult = (available.subdata(in: 0..<length), length)
            } else {
                // No length and no chunking: the body runs until the connection
                // closes, which cannot be detected from here. Record the head
                // and stop parsing rather than guess.
                finish(status: status, body: nil, contentType: headers["content-type"])
                return abandon()
            }

            guard let bodyResult else { return }  // incomplete chunked body

            finish(status: status, body: bodyResult.body, contentType: headers["content-type"])
            consume(&responseBuffer, upTo: bodyStart + bodyResult.consumed, scanned: &responseScanned)
        }
    }

    private func finish(status: Int, body: Data?, contentType: String?) {
        guard !pending.isEmpty else { return abandon() }

        var record = pending.removeFirst()
        let started = startTimes.isEmpty ? record.startedAt : startTimes.removeFirst()

        record.statusCode = status
        record.durationMs = Date().timeIntervalSince(started) * 1000

        if let body, let text = String(data: body, encoding: .utf8) {
            record.responseBody = BodySanitiser.sanitise(text)
            if contentType?.contains("text/event-stream") == true {
                applyStreamedResponse(text, to: &record)
            } else {
                applyJSONResponse(text, to: &record)
            }
        }

        onRecord?(record)
    }

    /// Non-streamed: the whole completion in one JSON object.
    private func applyJSONResponse(_ text: String, to record: inout RequestRecord) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let usage = object["usage"] as? [String: Any] {
            record.promptTokens = usage["prompt_tokens"] as? Int
            record.completionTokens = usage["completion_tokens"] as? Int
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return
        }
        record.finishReason = first["finish_reason"] as? String
        guard let message = first["message"] as? [String: Any] else { return }

        // A tool call answers with an empty `content` and puts the substance in
        // `tool_calls`. Assigning that empty string was worse than assigning
        // nothing: the detail pane falls back to the raw body with `??`, and a
        // non-nil empty string is not nil, so the fallback never ran and every
        // tool response read as "No response body".
        let content = message["content"] as? String ?? ""
        let rendered = content.isEmpty
            ? Self.describeToolCalls(message["tool_calls"])
            : content
        if let rendered, !rendered.isEmpty {
            record.responseText = BodySanitiser.sanitise(rendered)
        }
    }

    /// Renders tool calls as something readable in the detail pane. The whole
    /// point of Insights is seeing what a client actually got, and for a tool
    /// call that is the name and the arguments rather than any prose.
    static func describeToolCalls(_ raw: Any?) -> String? {
        guard let calls = raw as? [[String: Any]], !calls.isEmpty else { return nil }
        let lines = calls.compactMap { call -> String? in
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let arguments = function["arguments"] as? String ?? ""
            return arguments.isEmpty ? "\(name)()" : "\(name)(\(arguments))"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Streamed: a run of `data: {...}` events whose deltas have to be stitched
    /// back into the message the user actually saw.
    private func applyStreamedResponse(_ text: String, to record: inout RequestRecord) {
        var assembled = ""
        var toolNames: [Int: String] = [:]
        var toolArguments: [Int: String] = [:]

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Usage normally rides on the final event.
            if let usage = object["usage"] as? [String: Any] {
                record.promptTokens = usage["prompt_tokens"] as? Int ?? record.promptTokens
                record.completionTokens = usage["completion_tokens"] as? Int ?? record.completionTokens
            }
            guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
                continue
            }
            if let reason = first["finish_reason"] as? String {
                record.finishReason = reason
            }
            guard let delta = first["delta"] as? [String: Any] else { continue }
            if let content = delta["content"] as? String {
                assembled += content
            }
            // Streamed tool calls arrive in fragments keyed by index: the name
            // once, then the arguments a few characters at a time. Collecting
            // them by index is the only way to end up with the call that was
            // actually made.
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let index = call["index"] as? Int ?? 0
                    guard let function = call["function"] as? [String: Any] else { continue }
                    if let name = function["name"] as? String, !name.isEmpty {
                        toolNames[index] = name
                    }
                    if let fragment = function["arguments"] as? String {
                        toolArguments[index, default: ""] += fragment
                    }
                }
            }
        }

        if assembled.isEmpty, !toolNames.isEmpty {
            assembled = toolNames.keys.sorted().map { index in
                let arguments = toolArguments[index] ?? ""
                return arguments.isEmpty
                    ? "\(toolNames[index] ?? "")()"
                    : "\(toolNames[index] ?? "")(\(arguments))"
            }.joined(separator: "\n")
        }

        if !assembled.isEmpty {
            record.responseText = BodySanitiser.sanitise(assembled)
        }
    }

    // MARK: - Buffer handling

    /// Searches only the bytes that have arrived since last time, less the
    /// three-byte overlap a four-byte terminator could straddle.
    private func nextHeaderEnd(in buffer: Data, scanned: inout Int) -> Range<Int>? {
        let from = max(0, min(scanned - (Self.headerTerminator.count - 1), buffer.count))
        guard from < buffer.count else {
            scanned = buffer.count
            return nil
        }
        if let found = buffer.range(of: Self.headerTerminator, options: [], in: from..<buffer.count) {
            return found
        }
        scanned = buffer.count
        return nil
    }

    private func consume(_ buffer: inout Data, upTo index: Int, scanned: inout Int) {
        buffer.removeSubrange(0..<index)
        scanned = 0
    }

    private func abandon() {
        abandoned = true
        // Anything still waiting for a response will never get one; emit it so
        // the request is at least visible, flagged as incomplete.
        for var record in pending {
            record.parseFailed = true
            onRecord?(record)
        }
        pending.removeAll()
        startTimes.removeAll()
        requestBuffer.removeAll()
        responseBuffer.removeAll()
        requestScanned = 0
        responseScanned = 0
    }

    private static func headers(from lines: some Sequence<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    /// Reassembles a chunked body. Returns nil while it is still arriving.
    private static func dechunk(_ data: Data) -> (body: Data, consumed: Int)? {
        var body = Data()
        var offset = 0

        while true {
            guard let lineEnd = data.range(of: crlf, options: [], in: offset..<data.count) else {
                return nil
            }
            let sizeLine = data.subdata(in: offset..<lineEnd.lowerBound)
            guard let sizeText = String(data: sizeLine, encoding: .utf8) else { return nil }

            // A chunk size may carry extensions after a semicolon.
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }

            let chunkStart = lineEnd.upperBound
            if size == 0 {
                // No trailers is the common `0\r\n\r\n` case. With trailers,
                // consume the entire trailer section through its empty line.
                if data.count >= chunkStart + crlf.count,
                   data.subdata(in: chunkStart..<(chunkStart + crlf.count)) == crlf {
                    return (body, chunkStart + crlf.count)
                }
                guard let end = data.range(
                    of: headerTerminator, options: [], in: chunkStart..<data.count)
                else { return nil }
                return (body, end.upperBound)
            }

            guard size <= Int.max - chunkStart - crlf.count else { return nil }
            let chunkEnd = chunkStart + size
            guard data.count >= chunkEnd + 2 else { return nil }
            guard data.subdata(in: chunkEnd..<(chunkEnd + crlf.count)) == crlf else {
                return nil
            }
            body.append(data.subdata(in: chunkStart..<chunkEnd))
            offset = chunkEnd + 2  // skip the CRLF after the chunk
        }
    }
}
