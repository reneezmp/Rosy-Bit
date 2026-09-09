import Combine
import Foundation
import Security

enum CloudProviderKind: String, Codable, CaseIterable, Identifiable {
    case deepSeek
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .custom: return "Custom Provider"
        }
    }
}

struct CloudProviderConfiguration: Codable, Equatable {
    var kind: CloudProviderKind
    var name: String
    var endpoint: String
    var model: String
    var maxTokens: Int

    static let deepSeekDefault = CloudProviderConfiguration(
        kind: .deepSeek,
        name: "DeepSeek",
        endpoint: "https://api.deepseek.com/v1/chat/completions",
        model: "deepseek-v4-flash",
        maxTokens: 1024)

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    func validated() throws -> CloudProviderConfiguration {
        var result = self
        result.name = kind == .deepSeek
            ? "DeepSeek"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.maxTokens = min(max(maxTokens, 64), 8192)

        guard !result.name.isEmpty else { throw CloudProviderError.missingName }
        guard !result.model.isEmpty else { throw CloudProviderError.missingModel }

        if kind == .deepSeek {
            result.endpoint = Self.deepSeekDefault.endpoint
        } else {
            result.endpoint = try Self.normalizedEndpoint(endpoint).absoluteString
        }
        return result
    }

    static func normalizedEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            throw CloudProviderError.invalidEndpoint
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "/" {
            path = "/v1/chat/completions"
        } else if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path
        guard let url = components.url else { throw CloudProviderError.invalidEndpoint }
        return url
    }
}

enum CloudProviderError: LocalizedError, Equatable {
    case missingName
    case missingModel
    case missingAPIKey
    case invalidEndpoint
    case keychain(OSStatus)
    case notConfigured
    case http(provider: String, status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            return "Give the custom provider a name."
        case .missingModel:
            return "Enter the provider's model ID."
        case .missingAPIKey:
            return "Enter an API key. It will be stored in your Mac's Keychain."
        case .invalidEndpoint:
            return "Enter an HTTPS base URL or chat-completions URL."
        case .keychain(let status):
            return "The API key could not be saved in Keychain (\(status))."
        case .notConfigured:
            return "No cloud model is configured. Open Model → Cloud Model…"
        case .http(let provider, let status, let message):
            let detail = message.isEmpty ? "No details returned." : message
            return "\(provider) answered with HTTP \(status): \(detail)"
        }
    }
}

enum CloudCredentialStore {
    private static let service = "com.rosybit.app.cloud-provider"
    private static let account = "active-api-key"

    static func save(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw CloudProviderError.keychain(errSecParam)
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributes = identity
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        // Add first, and replace on collision rather than updating in place —
        // `SecItemUpdate` must open the existing item, which asks macOS for a
        // permission an ad-hoc-signed build loses every time it is rebuilt.
        // See the matching note in `KagiCredentialStore.save`.
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemDelete(identity as CFDictionary)
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudProviderError.keychain(status) }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class CloudModelStore: ObservableObject {
    static let shared = CloudModelStore()

    private static let configurationKey = "cloudProviderConfiguration"
    private static let sourceKey = "inferenceSource"

    @Published private(set) var configuration: CloudProviderConfiguration?
    @Published private(set) var isCloudSelected: Bool
    @Published private(set) var activeRequests = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = nil
        if let data = defaults.data(forKey: Self.configurationKey) {
            configuration = try? JSONDecoder().decode(CloudProviderConfiguration.self, from: data)
        }
        isCloudSelected = defaults.string(forKey: Self.sourceKey) == "cloud"
    }

    var isReady: Bool {
        readinessError == nil
    }

    var readinessError: CloudProviderError? {
        guard configuration != nil else { return .notConfigured }
        if configuration?.kind == .deepSeek, CloudCredentialStore.load() == nil {
            return .missingAPIKey
        }
        return nil
    }

    var selectedDescription: String? {
        guard isCloudSelected, let configuration else { return nil }
        return "\(configuration.displayName) · \(configuration.model)"
    }

    var registeredDescription: String? {
        guard let configuration else { return nil }
        return "\(configuration.displayName) · \(configuration.model)"
    }

    func saveAndSelect(_ candidate: CloudProviderConfiguration, apiKey: String) throws {
        let validated = try candidate.validated()
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameCredentialOwner = configuration?.kind == validated.kind
            && configuration?.endpoint == validated.endpoint
        if !trimmedKey.isEmpty {
            try CloudCredentialStore.save(trimmedKey)
        } else if validated.kind == .deepSeek,
                  (!sameCredentialOwner || CloudCredentialStore.load() == nil) {
            throw CloudProviderError.missingAPIKey
        } else if !sameCredentialOwner {
            CloudCredentialStore.delete()
        }

        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: Self.configurationKey)
        defaults.set("cloud", forKey: Self.sourceKey)
        configuration = validated
        isCloudSelected = true
    }

    func selectLocal() {
        defaults.set("local", forKey: Self.sourceKey)
        isCloudSelected = false
    }

    func selectCloud() {
        guard configuration != nil else { return }
        defaults.set("cloud", forKey: Self.sourceKey)
        isCloudSelected = true
    }

    func forget() {
        CloudCredentialStore.delete()
        defaults.removeObject(forKey: Self.configurationKey)
        defaults.set("local", forKey: Self.sourceKey)
        configuration = nil
        isCloudSelected = false
    }

    func beginRequest() { activeRequests += 1 }
    func endRequest() { activeRequests = max(0, activeRequests - 1) }

    static var selectedConfiguration: CloudProviderConfiguration? {
        guard UserDefaults.standard.string(forKey: sourceKey) == "cloud",
              let data = UserDefaults.standard.data(forKey: configurationKey) else { return nil }
        return try? JSONDecoder().decode(CloudProviderConfiguration.self, from: data)
    }
}

enum CloudRequestBuilder {
    static func payload(
        configuration: CloudProviderConfiguration,
        messages: [[String: Any]],
        tools: [[String: Any]]? = nil,
        toolChoice: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": configuration.maxTokens,
        ]
        if let tools, !tools.isEmpty { result["tools"] = tools }
        if let toolChoice { result["tool_choice"] = toolChoice }

        if configuration.kind == .deepSeek {
            // DeepSeek thinking mode has a stricter history contract: when
            // tools are present, every prior assistant reasoning_content must
            // be replayed. Rosy deliberately stores only visible conversation,
            // so the first version disables thinking rather than silently
            // constructing an invalid or privacy-surprising transcript.
            // `thinking` is a documented DeepSeek field, alongside
            // `reasoning_effort`. Note the related constraint before changing
            // anything here: while thinking is active, V4 rejects
            // `tool_choice: "required"` and named-function choices with HTTP
            // 400. Rosy only ever sends "auto" or "none", both of which are
            // accepted, and that is not an accident.
            result["thinking"] = ["type": "disabled"]
        } else {
            result["temperature"] = Config.temperature
        }
        return result
    }

    static func encoded(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
