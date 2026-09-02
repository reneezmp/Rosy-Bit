import XCTest
@testable import RosyBit

final class CloudInsightsTests: XCTestCase {
    func testDirectCloudRequestLooksLikeAnOrdinaryChatInsightWithoutCredentials() throws {
        let messageID = UUID()
        let body = #"{"max_tokens":512,"messages":[{"content":"Rules","role":"system"},{"content":"Hello","role":"user"}],"model":"deepseek-v4-flash","stream":true,"thinking":{"type":"disabled"}}"#

        let record = RequestRecord.directCloudRequest(
            url: try XCTUnwrap(URL(string: "https://api.deepseek.com/v1/chat/completions")),
            body: body,
            chatMessageID: messageID)

        XCTAssertEqual(record.method, "POST")
        XCTAssertEqual(record.path, "api.deepseek.com/v1/chat/completions")
        XCTAssertTrue(record.isChatCompletion)
        XCTAssertEqual(record.chatMessageID, messageID)
        XCTAssertEqual(record.model, "deepseek-v4-flash")
        XCTAssertEqual(record.maxTokens, 512)
        XCTAssertTrue(record.streamed)
        XCTAssertEqual(record.promptMessages.map(\.role), ["system", "user"])
        XCTAssertEqual(record.promptMessages.map(\.content), ["Rules", "Hello"])
        XCTAssertFalse(record.requestBody?.contains("Authorization") ?? true)
    }

    func testDirectCloudRequestStillAppliesBodyCredentialRedaction() throws {
        let body = #"{"api_key":"should-never-be-here","messages":[],"model":"test"}"#

        let record = RequestRecord.directCloudRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions")),
            body: body,
            chatMessageID: nil)

        XCTAssertFalse(record.requestBody?.contains("should-never-be-here") ?? true)
        XCTAssertTrue(record.requestBody?.contains("<redacted>") ?? false)
    }
}
