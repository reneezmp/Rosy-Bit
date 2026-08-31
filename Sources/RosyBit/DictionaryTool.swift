import CoreServices
import Foundation

/// The first and deliberately narrow capability Rosy Bit gives its model.
///
/// Dictionary Services reads the dictionaries already enabled on this Mac. It
/// does not need a network connection, mutate anything, or grant the model a
/// general route into the system.
enum DictionaryTool {
    static let name = "dictionary_lookup"

    /// Dictionary Services can return an entire bilingual dictionary article
    /// for an ordinary-looking term. Sending tens of thousands of characters
    /// through a 2,048-token context makes Rosy prefill text she cannot use and
    /// can keep both cores busy for minutes. About 1,800 characters leaves room
    /// for the system prompt, tool transcript, and a useful answer.
    static let maximumDefinitionCharacters = 1_800

    struct Call: Equatable {
        let id: String
        let term: String
        let rawArguments: String
    }

    enum ToolError: LocalizedError, Equatable {
        case unavailableForModel
        case unsupportedCall
        case malformedArguments
        case invalidTerm

        var errorDescription: String? {
            switch self {
            case .unavailableForModel:
                return "Dictionary lookup is available only with Bonsai 1.7B Q1_0."
            case .unsupportedCall:
                return "Rosy requested a tool that is not allowed."
            case .malformedArguments:
                return "Rosy produced an invalid dictionary request."
            case .invalidTerm:
                return "The dictionary term was empty or too long."
            }
        }
    }

    /// Tool calling is measured and enabled only for the exact model family
    /// that passed the harness. A larger parameter count is not evidence: the
    /// tested 4B build called tools on greetings and ignored genuine lookups.
    static func isAvailable(for modelName: String?) -> Bool {
        guard let name = modelName?.lowercased() else { return false }
        return name.contains("bonsai") && name.contains("1.7b") && name.contains("q1_0")
    }

    /// This is the canonical schema used by both prefix warming and live
    /// requests. Keeping one copy matters because even a wording difference
    /// moves the end of llama-server's reusable cached prefix.
    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "Look up a word or short term in the dictionaries enabled on this Mac. Use this when the user asks what a word means, for a definition, or about a word's origin. The returned entry is authoritative; do not invent senses or etymologies beyond it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "term": [
                        "type": "string",
                        "description": "The exact word or short term to look up."
                    ]
                ],
                "required": ["term"],
                "additionalProperties": false
            ]
        ]
    ]]

    static func parse(id: String?, name: String?, arguments: String) throws -> Call {
        guard name == Self.name else { throw ToolError.unsupportedCall }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["term"],
              let rawTerm = object["term"] as? String else {
            throw ToolError.malformedArguments
        }

        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 100,
              term.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ToolError.invalidTerm
        }

        return Call(
            id: (id?.isEmpty == false ? id! : "dictionary-call"),
            term: term,
            rawArguments: arguments)
    }

    static func lookup(_ term: String) -> String? {
        let range = CFRange(location: 0, length: (term as NSString).length)
        guard let value = DCSCopyTextDefinition(nil, term as CFString, range) else {
            return nil
        }
        return (value.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayedEntry(term: String, definition: String?) -> String {
        if let definition, !definition.isEmpty {
            let excerpt = boundedDefinition(definition)
            let fence = codeFence(for: excerpt.text)
            let notice = excerpt.wasShortened
                ? "\n\n*Entry shortened locally from \(excerpt.originalCount.formatted()) to \(excerpt.includedSourceCount.formatted()) source characters to protect Rosy’s context and CPU.*"
                : ""
            return "### Dictionary: \(term)\n\n\(fence)\n\(excerpt.text)\n\(fence)\(notice)\n\n### Rosy’s gloss\n\n"
        }
        return "### Dictionary: \(term)\n\n*No entry was found in the dictionaries enabled on this Mac.*\n\n### Rosy’s gloss\n\n"
    }

    struct DefinitionExcerpt: Equatable {
        let text: String
        let originalCount: Int
        let includedSourceCount: Int

        var wasShortened: Bool {
            originalCount > DictionaryTool.maximumDefinitionCharacters
        }
    }

    /// Cuts on the last natural boundary available near the limit. The suffix
    /// is outside Dictionary Services' text, so it is visibly editorial rather
    /// than masquerading as part of the source entry.
    static func boundedDefinition(_ definition: String) -> DefinitionExcerpt {
        let cleaned = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maximumDefinitionCharacters else {
            return DefinitionExcerpt(
                text: cleaned,
                originalCount: cleaned.count,
                includedSourceCount: cleaned.count)
        }

        let hardCut = String(cleaned.prefix(maximumDefinitionCharacters))
        let minimumUsefulCut = maximumDefinitionCharacters * 3 / 4
        let boundaries = ["\n\n", "\n", ". ", "; "]
        var cut = hardCut.endIndex
        for boundary in boundaries {
            if let range = hardCut.range(of: boundary, options: .backwards),
               hardCut.distance(from: hardCut.startIndex, to: range.upperBound) >= minimumUsefulCut {
                cut = range.upperBound
                break
            }
        }

        let excerpt = hardCut[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        return DefinitionExcerpt(
            text: excerpt + "\n[…entry shortened by Rosy Bit…]",
            originalCount: cleaned.count,
            includedSourceCount: excerpt.count)
    }

    /// Markdown fences may contain shorter runs of backticks. Choose one
    /// longer than anything in the entry so Dictionary Services text is always
    /// rendered as one literal block rather than accidentally becoming markup.
    private static func codeFence(for text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    static func observation(term: String, definition: String?) -> String {
        if let definition, !definition.isEmpty {
            let excerpt = boundedDefinition(definition)
            let scope = excerpt.wasShortened
                ? "This is a locally shortened excerpt of a longer entry. Discuss only what appears here."
                : "This is the complete returned entry."
            return "Authoritative local dictionary entry for \"\(term)\":\n\(excerpt.text)\n\n\(scope) Explain it briefly and faithfully. Do not add any sense, origin, spelling, or claim that is absent from the supplied text."
        }
        return "No entry for \"\(term)\" was found in the dictionaries enabled on this Mac. Say that plainly and do not invent a definition."
    }
}
