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
        static func user(_ content: String) -> Message { Message(role: "user", content: content) }
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
            do {
                guard let url = Config.chatCompletionsURL else { throw ChatError.notConfigured }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Lets Insights tell Rosy Bit's own traffic from a client's.
                request.setValue("RosyBit", forHTTPHeaderField: "X-RosyBit-Source")
                // Generation here is measured in minutes, not seconds.
                request.timeoutInterval = 900

                let payload: [String: Any] = [
                    "model": "rosybit",
                    "stream": true,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] },
                ]
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
}
