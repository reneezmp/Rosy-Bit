import AppKit
import Foundation

/// Application mutations use a narrow product-side grammar. The model sees
/// only the read-only app lookup operation. Model-led actions arrive through a
/// separate closed-schema adapter and still resolve against installed/running
/// apps, standard folders, and existing paths here.
enum AppsFinderTool {
    static let name = "apps_find"

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "Find an installed Mac application by name. This only searches; opening and quitting apps are handled directly from explicit user commands.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The application name to find."]
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

    enum Command: Equatable {
        case openApp(String)
        case quitApp(String)
        case openFolder(Folder)
        case reveal(String)
    }

    enum Folder: String, Equatable {
        case home, desktop, documents, downloads, applications
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case appNotFound(String)
        case appNotRunning(String)
        case pathNotFound

        var errorDescription: String? {
            switch self {
            case .malformedArguments: return "Rosy produced an invalid app lookup."
            case .appNotFound(let name): return "I couldn't find an installed app named **\(name)**."
            case .appNotRunning(let name): return "**\(name)** is not currently running."
            case .pathNotFound: return "That file or folder does not exist on this Mac."
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["query"],
              let raw = object["query"] as? String else { throw ToolError.malformedArguments }
        let query = cleanName(raw)
        guard !query.isEmpty, query.count <= 80 else { throw ToolError.malformedArguments }
        return Call(id: id?.isEmpty == false ? id! : "apps-find-call", query: query, rawArguments: arguments)
    }

    static func explicitCommand(in message: String) -> Command? {
        guard let prompt = singleLine(message) else { return nil }
        if let folder = capture(prompt, #"^(?:please\s+)?open\s+(?:my\s+|the\s+)?(home|desktop|documents|downloads|applications)(?:\s+folder)?(?:\s+in\s+finder)?(?:,?\s+please)?[?!.]*$"#),
           let value = Folder(rawValue: folder.lowercased()) {
            return .openFolder(value)
        }
        if let name = capture(prompt, #"^(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?(.+?)(?:\s+app)?(?:,?\s+please)?[?!.]*$"#) {
            let clean = cleanName(name)
            if clean.localizedCaseInsensitiveCompare("finder") == .orderedSame { return .openFolder(.home) }
            return clean.isEmpty ? nil : .openApp(clean)
        }
        if let name = capture(prompt, #"^(?:please\s+)?(?:quit|close)\s+(?:the\s+)?(.+?)(?:\s+app)?(?:,?\s+please)?[?!.]*$"#) {
            let clean = cleanName(name)
            return clean.isEmpty ? nil : .quitApp(clean)
        }
        if let path = capture(prompt, #"^(?:please\s+)?(?:reveal|show)\s+(.+?)\s+in\s+finder(?:,?\s+please)?[?!.]*$"#) {
            return .reveal(unquote(path))
        }
        return nil
    }

    @MainActor
    static func execute(_ command: Command) async throws -> String {
        switch command {
        case .openApp(let name):
            guard let url = applicationURL(named: name) else { throw ToolError.appNotFound(name) }
            try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return "Opened **\(url.deletingPathExtension().lastPathComponent)**."
        case .quitApp(let name):
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
                || $0.bundleURL?.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            guard !matches.isEmpty else { throw ToolError.appNotRunning(name) }
            matches.forEach { _ = $0.terminate() }
            return "Asked **\(matches[0].localizedName ?? name)** to quit."
        case .openFolder(let folder):
            let url = folderURL(folder)
            NSWorkspace.shared.open(url)
            return "Opened **\(folder.rawValue.capitalized)** in Finder."
        case .reveal(let rawPath):
            let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL
            guard rawPath.count <= 1_024, FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError.pathNotFound
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Revealed **\(url.lastPathComponent)** in Finder."
        }
    }

    static func search(_ query: String) -> String {
        let matches = installedApplications().filter {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query)
        }.prefix(10)
        guard !matches.isEmpty else { return "No installed applications matched \"\(query)\"." }
        return matches.map { "- \($0.deletingPathExtension().lastPathComponent) — \($0.path)" }
            .joined(separator: "\n")
    }

    static func observation(query: String) -> String {
        "Authoritative installed-application search for \(query):\n\(search(query))"
    }

    private static func applicationURL(named name: String) -> URL? {
        installedApplications().first {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame
        } ?? installedApplications().first {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(name)
        }
    }

    private static func installedApplications() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var result: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                    result.append(url)
                }
                // Installed-app lookup must remain bounded even on unusual
                // machines with enormous managed application trees.
                if result.count >= 2_000 { break }
            }
        }
        return result
    }

    private static func folderURL(_ folder: Folder) -> URL {
        let fm = FileManager.default
        switch folder {
        case .home: return fm.homeDirectoryForCurrentUser
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .documents: return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .applications: return URL(fileURLWithPath: "/Applications")
        }
    }

    private static func cleanName(_ value: String) -> String {
        unquote(value.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: #"(?i)\s+app$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\.app$"#, with: "", options: .regularExpression)
    }
    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
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
