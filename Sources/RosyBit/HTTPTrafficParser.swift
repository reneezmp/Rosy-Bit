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
/// Only ever touched from its connection's queue.
final class HTTPTrafficParser {

    /// Called when a response completes and the record is final.
    var onRecord: ((RequestRecord) -> Void)?

    private var requestBuffer = Data()
    private var responseBuffer = Data()

    /// Requests seen but not yet answered, oldest first.
    private var pending: [RequestRecord] = []
    private var startTimes: [Date] = []

    /// Once lost, stay lost: a desynchronised parser invents records.
    private var abandoned = false

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    // MARK: - Client → server

    func consumeRequest(_ data: Data) {
        guard !abandoned else { return }
        requestBuffer.append(data)

        while let headerEnd = range(of: Self.headerTerminator, in: requestBuffer) {
            let headData = requestBuffer.subdata(in: requestBuffer.startIndex..<headerEnd.lowerBound)
            guard let head = String(data: headData, encoding: .utf8) else { return abandon() }

            let lines = head.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return abandon() }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return abandon() }

            let headers = Self.headers(from: lines.dropFirst())
            let contentLength = Int(headers["content-length"] ?? "") ?? 0

            let bodyStart = headerEnd.upperBound
            guard requestBuffer.count - bodyStart >= contentLength else { return }  // wait for more

            var record = RequestRecord(method: parts[0], path: parts[1])
            if contentLength > 0 {
                let bodyData = requestBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                let body = String(data: bodyData, encoding: .utf8)
                record.requestBody = BodySanitiser.sanitise(body)
                applyRequestParameters(from: body, to: &record)
            }

            pending.append(record)
            startTimes.append(Date())
            requestBuffer = requestBuffer.subdata(
                in: (bodyStart + contentLength)..<requestBuffer.endIndex)
        }
    }

    private func applyRequestParameters(from body: String?, to record: inout RequestRecord) {
        guard let body, let data = body.data(using: .utf8),
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

        while let headerEnd = range(of: Self.headerTerminator, in: responseBuffer) {
            let headData = responseBuffer.subdata(in: responseBuffer.startIndex..<headerEnd.lowerBound)
            guard let head = String(data: headData, encoding: .utf8) else { return abandon() }

            let lines = head.components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return abandon() }
            let statusParts = statusLine.split(separator: " ").map(String.init)
            guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return abandon() }

            let headers = Self.headers(from: lines.dropFirst())
            let bodyStart = headerEnd.upperBound
            let available = responseBuffer.subdata(in: bodyStart..<responseBuffer.endIndex)

            let bodyResult: (body: Data, consumed: Int)?
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                bodyResult = Self.dechunk(available)
            } else if let length = Int(headers["content-length"] ?? "") {
                guard available.count >= length else { return }  // wait for more
                bodyResult = (available.subdata(in: 0..<length), length)
            } else {
                // No length and no chunking: the body runs until the connection
                // closes, which we cannot detect from here. Record the head and
                // stop parsing rather than guess.
                finish(status: status, body: nil, contentType: headers["content-type"])
                return abandon()
            }

            guard let bodyResult else { return }  // incomplete chunked body

            finish(
                status: status,
                body: bodyResult.body,
                contentType: headers["content-type"])

            responseBuffer = responseBuffer.subdata(
                in: (bodyStart + bodyResult.consumed)..<responseBuffer.endIndex)
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
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            record.responseText = BodySanitiser.sanitise(content)
        }
    }

    /// Streamed: a run of `data: {...}` events whose deltas have to be stitched
    /// back into the message the user actually saw.
    private func applyStreamedResponse(_ text: String, to record: inout RequestRecord) {
        var assembled = ""

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
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                assembled += content
            }
        }

        if !assembled.isEmpty {
            record.responseText = BodySanitiser.sanitise(assembled)
        }
    }

    // MARK: - Helpers

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
        var offset = data.startIndex
        let newline = Data("\r\n".utf8)

        while true {
            guard let lineEnd = range(of: newline, in: data, from: offset) else { return nil }
            let sizeLine = data.subdata(in: offset..<lineEnd.lowerBound)
            guard let sizeText = String(data: sizeLine, encoding: .utf8) else { return nil }

            // A chunk size may carry extensions after a semicolon.
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }

            let chunkStart = lineEnd.upperBound
            if size == 0 {
                // Trailer plus the final CRLF.
                guard let end = range(of: newline, in: data, from: chunkStart) else { return nil }
                return (body, end.upperBound - data.startIndex)
            }

            let chunkEnd = chunkStart + size
            guard data.count >= chunkEnd - data.startIndex + 2 else { return nil }
            body.append(data.subdata(in: chunkStart..<chunkEnd))
            offset = chunkEnd + 2  // skip the CRLF after the chunk
        }
    }

    private func range(of pattern: Data, in data: Data) -> Range<Int>? {
        Self.range(of: pattern, in: data, from: data.startIndex)
    }

    private static func range(of pattern: Data, in data: Data, from start: Int) -> Range<Int>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let limit = data.endIndex - pattern.count
        guard start <= limit else { return nil }

        for index in start...limit {
            if data.subdata(in: index..<(index + pattern.count)) == pattern {
                return index..<(index + pattern.count)
            }
        }
        return nil
    }
}
