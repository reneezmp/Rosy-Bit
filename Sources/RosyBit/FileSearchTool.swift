import Foundation

/// Bounded, read-only Spotlight search. `mdfind` is invoked directly with an
/// argument array—never through a shell—so a query remains data rather than an
/// executable command.
enum FileSearchTool {
    static let name = "file_search"
    static let maximumResults = 12

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "Search this Mac's Spotlight index for files and folders. Returns at most twelve local paths and never changes files.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "A short filename or Spotlight search phrase."]
                ],
                "required": ["query"],
                "additionalProperties": false
            ]
        ]
    ]]

    struct Call: Equatable {
        let id: String
        let query: String
        let rawArguments: String
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case searchFailed

        var errorDescription: String? {
            switch self {
            case .malformedArguments: return "Rosy produced an invalid file search."
            case .searchFailed: return "Spotlight could not complete that file search."
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["query"],
              let raw = object["query"] as? String else { throw ToolError.malformedArguments }
        let query = clean(raw)
        guard valid(query) else { throw ToolError.malformedArguments }
        return Call(id: id?.isEmpty == false ? id! : "file-search-call", query: query, rawArguments: arguments)
    }

    static func explicitQuery(in message: String) -> String? {
        guard explicitFilenameQuery(in: message) == nil else { return nil }
        guard let prompt = singleLine(message) else { return nil }
        let patterns = [
            #"^(?:please\s+)?(?:find|search\s+for|look\s+for)\s+(?:my\s+)?(?:files?\s+)?[\"']?(.+?)[\"']?(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?search\s+(?:my\s+)?(?:mac|files?)\s+for\s+[\"']?(.+?)[\"']?(?:,?\s+please)?[?!.]*$"#,
        ]
        for pattern in patterns {
            if let value = capture(prompt, pattern) {
                let query = clean(value)
                return valid(query) ? query : nil
            }
        }
        return nil
    }

    /// "Named" and "called" describe the filesystem name, not the document
    /// body. Keep that semantic distinction before the broader router above.
    static func explicitFilenameQuery(in message: String) -> String? {
        guard let prompt = singleLine(message),
              let value = capture(
                prompt,
                #"^(?:please\s+)?(?:find|search\s+for|look\s+for)\s+(?:my\s+)?files?\s+(?:named|called)\s+[\"']?(.+?)[\"']?(?:,?\s+please)?[?!.]*$"#)
        else { return nil }
        let query = clean(value)
        return valid(query) ? query : nil
    }

    static func result(for query: String, filenamesOnly: Bool = false) throws -> String {
        guard valid(query) else { throw ToolError.malformedArguments }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        if filenamesOnly {
            // Metadata predicate, passed as one literal process argument. The
            // wildcard belongs to Rosy; wildcard characters supplied by the
            // user are escaped and cannot broaden the query.
            let escaped = query
                .replacingOccurrences(of: #"\"#, with: #"\\"#)
                .replacingOccurrences(of: #"""#, with: #"\""#)
                .replacingOccurrences(of: "*", with: #"\*"#)
                .replacingOccurrences(of: "?", with: #"\?"#)
            process.arguments = [#"kMDItemFSName == "*\#(escaped)*"cd"#]
        } else {
            // `-interpret` gives the same friendly Spotlight interpretation
            // used by Finder while preserving direct argument passing.
            process.arguments = ["-interpret", query]
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { throw ToolError.searchFailed }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError.searchFailed }
        let text = String(data: data, encoding: .utf8) ?? ""
        let paths = filteredPaths(
            text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { FileManager.default.fileExists(atPath: $0) },
            query: query,
            filenamesOnly: filenamesOnly)
            .prefix(maximumResults)
        guard !paths.isEmpty else { return "No Spotlight results for **\(query)**." }
        return "Spotlight found:\n" + paths.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return "- **\(name)** — `\(path)`"
        }.joined(separator: "\n")
    }

    static func observation(query: String, result: String) -> String {
        "Authoritative read-only Spotlight results for \(query):\n\(result.replacingOccurrences(of: "**", with: ""))"
    }

    static func filteredPaths(
        _ paths: [String],
        query: String,
        filenamesOnly: Bool
    ) -> [String] {
        guard filenamesOnly else { return paths }
        return paths.filter {
            URL(fileURLWithPath: $0).lastPathComponent
                .localizedCaseInsensitiveContains(query)
        }
    }

    private static func valid(_ query: String) -> Bool {
        !query.isEmpty && query.count <= 120
            && !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }
    private static func singleLine(_ message: String) -> String? {
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("[Timestamp:") == true { lines.removeFirst() }
        guard lines.count == 1 else { return nil }
        return lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
