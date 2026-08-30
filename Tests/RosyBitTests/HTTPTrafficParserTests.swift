import Foundation
import XCTest
@testable import RosyBit

final class HTTPTrafficParserTests: XCTestCase {

    func testNoContentAndNotModifiedCompleteTheirOwnRequests() {
        let parser = HTTPTrafficParser()
        var records: [RequestRecord] = []
        parser.onRecord = { records.append($0) }

        parser.consumeRequest(data(
            "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n"
            + "GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n"
            + "GET /third HTTP/1.1\r\nHost: localhost\r\n\r\n"))

        parser.consumeResponse(data(
            "HTTP/1.1 204 No Content\r\n\r\n"
            + "HTTP/1.1 304 Not Modified\r\nETag: example\r\n\r\n"
            + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"))

        XCTAssertEqual(records.map(\.path), ["/first", "/second", "/third"])
        XCTAssertEqual(records.map(\.statusCode), [204, 304, 200])
    }

    func testHeadResponseDoesNotWaitForDeclaredBodyLength() {
        let parser = HTTPTrafficParser()
        var records: [RequestRecord] = []
        parser.onRecord = { records.append($0) }

        parser.consumeRequest(data("HEAD /health HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        parser.consumeResponse(data(
            "HTTP/1.1 200 OK\r\nContent-Length: 123\r\nContent-Type: application/json\r\n\r\n"))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.path, "/health")
        XCTAssertEqual(records.first?.statusCode, 200)
        XCTAssertNil(records.first?.responseBody)
    }

    func testChunkedRequestBodyIsCapturedAcrossReads() {
        let parser = HTTPTrafficParser()
        var records: [RequestRecord] = []
        parser.onRecord = { records.append($0) }

        let body = #"{"model":"test","messages":[{"role":"user","content":"hello"}]}"#
        let request = data(
            "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n")
        let split = request.count / 2

        parser.consumeRequest(request.subdata(in: 0..<split))
        parser.consumeRequest(request.subdata(in: split..<request.count))
        parser.consumeResponse(data("HTTP/1.1 204 No Content\r\n\r\n"))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.requestBody, body)
        XCTAssertEqual(records.first?.model, "test")
        XCTAssertEqual(records.first?.promptMessages.first?.role, "user")
        XCTAssertEqual(records.first?.promptMessages.first?.content, "hello")
        XCTAssertFalse(records.first?.parseFailed ?? true)
    }

    func testChunkTrailersAreFullyConsumedBeforeNextResponse() {
        let parser = HTTPTrafficParser()
        var records: [RequestRecord] = []
        parser.onRecord = { records.append($0) }

        parser.consumeRequest(data(
            "GET /chunked HTTP/1.1\r\nHost: localhost\r\n\r\n"
            + "GET /after HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        parser.consumeResponse(data(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n"
            + "Content-Type: application/json\r\n\r\n"
            + "2\r\n{}\r\n0\r\nX-Trace: one\r\nX-Other: two\r\n\r\n"
            + "HTTP/1.1 204 No Content\r\n\r\n"))

        XCTAssertEqual(records.map(\.path), ["/chunked", "/after"])
        XCTAssertEqual(records.map(\.statusCode), [200, 204])
        XCTAssertEqual(records.first?.responseBody, "{}")
        XCTAssertTrue(records.allSatisfy { !$0.parseFailed })
    }

    /// A tool call answers with an empty `content`, and an empty string is not
    /// nil — so assigning it shadowed the raw-body fallback with `??` and the
    /// detail pane read "No response body" for every tool response.
    func testToolCallResponseIsShownRatherThanReadingAsEmpty() {
        let parser = HTTPTrafficParser()
        var records: [RequestRecord] = []
        parser.onRecord = { records.append($0) }

        let body = #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"dictionary_lookup","arguments":"{\"term\": \"petrichor\"}"}}]}}]}"#

        parser.consumeRequest(data(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        parser.consumeResponse(data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.finishReason, "tool_calls")
        XCTAssertEqual(
            records.first?.responseText,
            #"dictionary_lookup({"term": "petrichor"})"#)
    }

    /// Streamed tool calls arrive as fragments: the name once, then the
    /// arguments a few characters at a time, keyed by index.
    func testStreamedToolCallFragmentsAreStitchedBackTogether() {
        let parser = HTTPTrafficParser()
        var records: [RequestRecord] = []
        parser.onRecord = { records.append($0) }

        let events = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"volume_set","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"lev"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"el\": 30}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        let body = events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"

        parser.consumeRequest(data(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        parser.consumeResponse(data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.finishReason, "tool_calls")
        XCTAssertEqual(records.first?.responseText, #"volume_set({"level": 30})"#)
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
