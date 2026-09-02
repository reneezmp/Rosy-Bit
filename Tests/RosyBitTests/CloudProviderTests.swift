import XCTest
@testable import RosyBit

final class CloudProviderTests: XCTestCase {
    func testRegisteredCloudModelCanBeSelectedAgainWithoutReconfiguration() throws {
        let suite = "CloudProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CloudProviderConfiguration(
            kind: .custom,
            name: "My Cloud",
            endpoint: "https://example.com/v1/chat/completions",
            model: "qwen-cloud",
            maxTokens: 1024
        )
        defaults.set(try JSONEncoder().encode(configuration), forKey: "cloudProviderConfiguration")
        defaults.set("local", forKey: "inferenceSource")

        let store = CloudModelStore(defaults: defaults)
        XCTAssertEqual(store.registeredDescription, "My Cloud · qwen-cloud")
        XCTAssertFalse(store.isCloudSelected)

        store.selectCloud()
        XCTAssertTrue(store.isCloudSelected)
        XCTAssertEqual(defaults.string(forKey: "inferenceSource"), "cloud")
    }

    func testCustomBaseURLsBecomeChatCompletionEndpoints() throws {
        XCTAssertEqual(
            try CloudProviderConfiguration.normalizedEndpoint("https://example.com").absoluteString,
            "https://example.com/v1/chat/completions")
        XCTAssertEqual(
            try CloudProviderConfiguration.normalizedEndpoint("https://example.com/v1/").absoluteString,
            "https://example.com/v1/chat/completions")
        XCTAssertEqual(
            try CloudProviderConfiguration.normalizedEndpoint(
                "https://example.com/openai/v1/chat/completions").absoluteString,
            "https://example.com/openai/v1/chat/completions")
    }

    func testCustomProviderRequiresHTTPS() {
        XCTAssertThrowsError(
            try CloudProviderConfiguration.normalizedEndpoint("http://example.com/v1")) {
                XCTAssertEqual($0 as? CloudProviderError, .invalidEndpoint)
            }
        XCTAssertThrowsError(
            try CloudProviderConfiguration.normalizedEndpoint("example.com/v1")) {
                XCTAssertEqual($0 as? CloudProviderError, .invalidEndpoint)
            }
    }

    func testDeepSeekValidationUsesItsOfficialEndpointAndBoundsAnswerLimit() throws {
        let candidate = CloudProviderConfiguration(
            kind: .deepSeek,
            name: "Changed",
            endpoint: "https://not-deepseek.example/v1",
            model: "  deepseek-chat  ",
            maxTokens: 100_000)

        let validated = try candidate.validated()

        XCTAssertEqual(validated.name, "DeepSeek")
        XCTAssertEqual(validated.endpoint, CloudProviderConfiguration.deepSeekDefault.endpoint)
        XCTAssertEqual(validated.model, "deepseek-chat")
        XCTAssertEqual(validated.maxTokens, 8192)
    }

    func testDeepSeekPayloadPreservesPromptOrderAndDisablesThinking() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Rules"],
            ["role": "user", "content": "Question"],
        ]
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "dictionary_lookup"],
        ]]

        let payload = CloudRequestBuilder.payload(
            configuration: .deepSeekDefault,
            messages: messages,
            tools: tools,
            toolChoice: "auto")

        let wireMessages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(wireMessages[0]["role"] as? String, "system")
        XCTAssertEqual(wireMessages[1]["role"] as? String, "user")
        XCTAssertEqual(
            (payload["thinking"] as? [String: String])?["type"],
            "disabled")
        XCTAssertNil(payload["temperature"])
        XCTAssertEqual(payload["tool_choice"] as? String, "auto")
        XCTAssertEqual((payload["tools"] as? [[String: Any]])?.count, 1)
    }

    func testCustomProviderGetsOpenAICompatibleSamplingWithoutDeepSeekFields() throws {
        let configuration = try CloudProviderConfiguration(
            kind: .custom,
            name: "Example",
            endpoint: "https://example.com/v1",
            model: "example-model",
            maxTokens: 512).validated()

        let payload = CloudRequestBuilder.payload(
            configuration: configuration,
            messages: [["role": "user", "content": "Hello"]])

        XCTAssertEqual(payload["temperature"] as? Double, Config.temperature)
        XCTAssertNil(payload["thinking"])
        XCTAssertEqual(payload["max_tokens"] as? Int, 512)
        XCTAssertNil(payload["tools"])
        XCTAssertNil(payload["tool_choice"])
    }

    func testCloudPayloadEncodingIsCanonicalAndContainsNoCredential() throws {
        let payload = CloudRequestBuilder.payload(
            configuration: .deepSeekDefault,
            messages: [
                ["role": "system", "content": "Rules"],
                ["role": "user", "content": "Hello / world"],
            ])

        let first = try CloudRequestBuilder.encoded(payload)
        let second = try CloudRequestBuilder.encoded(payload)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))

        XCTAssertEqual(first, second)
        XCTAssertTrue(text.contains("Hello / world"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("api key"))
        XCTAssertFalse(text.contains("Authorization"))
    }
}
