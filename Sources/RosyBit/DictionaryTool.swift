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

    /// Routes only requests whose grammar makes a dictionary lookup
    /// unambiguous. Everything else stays with the model and `tool_choice:
    /// auto`, so a conversational use of "mean" cannot accidentally become a
    /// lookup. This is deliberately product-side routing: a tiny model should
    /// not spend a generation deciding whether "define X" asks for a
    /// definition.
    static func explicitLookupTerm(in message: String) -> String? {
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("[Timestamp:") == true {
            lines.removeFirst()
        }
        // Do not interpret a final line inside pasted text as an instruction.
        // The local router handles one plainly authored request, not documents.
        guard lines.count == 1 else { return nil }
        let prompt = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)

        // This fixed English idiom is a philosophical question, not a request
        // for Dictionary Services. `Define life` remains routable.
        let foldedPrompt = prompt
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
            .lowercased()
        if foldedPrompt == "what is the meaning of life"
            || foldedPrompt == "what's the meaning of life" {
            return nil
        }

        let patterns = [
            #"^(?:please\s+)?define\s+(?:the\s+(?:word|term)\s+)?(.+?)(?:\s+please)?[?.!]*$"#,
            #"^(?:please\s+)?what(?:'s|\s+is)\s+the\s+(?:meaning|definition)\s+of\s+(?:the\s+(?:word|term)\s+)?(.+?)(?:\s+please)?[?.!]*$"#,
            #"^(?:please\s+)?what\s+does\s+(?:the\s+(?:word|term)\s+)?(.+?)\s+mean(?:\s+in\s+english)?(?:\s+please)?[?.!]*$"#,
            #"^(?:please\s+)?(?:look\s+up)\s+(.+?)(?:\s+in\s+the\s+dictionary)?(?:\s+please)?[?.!]*$"#,
            #"^(?:please\s+)?(?:meaning|definition)\s+of\s+(?:the\s+(?:word|term)\s+)?(.+?)(?:\s+please)?[?.!]*$"#,
            #"^(?:please\s+)?(?:can|could|would)\s+you\s+(?:please\s+)?tell\s+me\s+the\s+(?:meaning|definition)\s+of\s+(?:the\s+(?:word|term)\s+)?(.+?)(?:\s+please)?[?.!]*$"#,
            #"^(?:please\s+)?i\s+(?:need|want)\s+(?:a|the)\s+definition\s+(?:for|of)\s+(?:the\s+(?:word|term)\s+)?(.+?)(?:\s+please)?[?.!]*$"#,
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]) else { continue }
            let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
            guard let match = expression.firstMatch(in: prompt, range: range),
                  match.numberOfRanges == 2,
                  let capturedRange = Range(match.range(at: 1), in: prompt),
                  let term = normalizedExplicitTerm(String(prompt[capturedRange])) else {
                continue
            }
            return term
        }
        return nil
    }

    static func routedCall(term: String) -> Call {
        let data = try? JSONSerialization.data(withJSONObject: ["term": term])
        let arguments = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"term":""}"#
        return Call(id: "dictionary-route", term: term, rawArguments: arguments)
    }

    private static func normalizedExplicitTerm(_ raw: String) -> String? {
        var term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        term = term.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        term = term.trimmingCharacters(in: .whitespacesAndNewlines)

        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`")
        ]
        for (opening, closing) in quotePairs where term.first == opening && term.last == closing {
            term.removeFirst()
            term.removeLast()
            term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        guard !term.isEmpty, term.count <= 100,
              term.split(whereSeparator: { $0.isWhitespace }).count <= 6 else {
            return nil
        }
        let rejected = ["it", "this", "that", "these", "those", "you", "i", "something"]
        guard !rejected.contains(term.lowercased()) else { return nil }

        var allowed = CharacterSet.letters
        allowed.formUnion(.decimalDigits)
        allowed.formUnion(.whitespaces)
        allowed.formUnion(CharacterSet(charactersIn: "-'’"))
        guard term.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return term
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
            let displayedDefinition = formattedDefinitionForDisplay(excerpt.text)
            let fence = codeFence(for: displayedDefinition)
            let notice = excerpt.wasShortened
                ? "\n\n*Entry shortened locally from \(excerpt.originalCount.formatted()) to \(excerpt.includedSourceCount.formatted()) source characters to protect Rosy’s context and CPU.*"
                : ""
            return "### Dictionary: \(term)\n\n\(fence)\n\(displayedDefinition)\n\(fence)\(notice)\n\n### Rosy’s gloss\n\n"
        }
        return "### Dictionary: \(term)\n\n*No entry was found in the dictionaries enabled on this Mac.*\n\n### Rosy’s gloss\n\n"
    }

    /// Dictionary Services returns a rich article as one flat string. Restore
    /// its visible hierarchy without rewriting the source: every character
    /// remains in order and this function inserts whitespace only.
    static func formattedDefinitionForDisplay(_ definition: String) -> String {
        let cleaned = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return cleaned }

        var header: String?
        var body = cleaned
        if let firstPipe = cleaned.range(of: " | "),
           let secondPipe = cleaned.range(
               of: " | ",
               range: firstPipe.upperBound..<cleaned.endIndex) {
            header = String(cleaned[..<secondPipe.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(cleaned[secondPipe.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Major dictionary labels and later parts of speech begin new blocks.
        body = replacingMatches(
            in: body,
            pattern: #"\s+(ORIGIN|PHRASES|DERIVATIVES)\s+"#,
            with: "\n\n$1\n")
        body = replacingMatches(
            in: body,
            pattern: #"\.\s+(noun|verb|adjective|adverb|exclamation|preposition|conjunction|pronoun|determiner)(?=\s|$)"#,
            with: ".\n\n$1")

        // Numbered and bullet senses get breathing room. Restrict numbered
        // boundaries to a preceding full stop so years and quantities inside
        // definitions are never mistaken for sense numbers.
        body = replacingMatches(
            in: body,
            pattern: #"\.\s+([2-9][0-9]*)\s+"#,
            with: ".\n\n$1 ")
        body = body.replacingOccurrences(of: " ● ", with: "\n\n● ")
        body = replacingMatches(
            in: body,
            pattern: #"^((?:noun|verb|adjective|adverb|exclamation|preposition|conjunction|pronoun|determiner)(?:\s+\[[^\]]+\])?)\s+([1-9][0-9]*)\s+"#,
            with: "$1\n\n$2 ")

        // Dictionary articles conventionally place examples after colons and
        // separate parallel examples with pipes. Preserve those delimiters and
        // merely move the examples onto indented lines.
        body = replacingMatches(in: body, pattern: #":\s+"#, with: ":\n    ")
        body = body.replacingOccurrences(of: " | ", with: "\n    | ")

        let formattedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let header, !formattedBody.isEmpty else { return formattedBody }
        return "\(header)\n\n\(formattedBody)"
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: template)
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
