import EventKit
import Foundation

/// Native Apple Reminders integration. State changes are accepted only through
/// explicit one-line commands parsed by Rosy itself. Guided mode is read-only;
/// the Model-led adapter can request the same mutations only after validating
/// a closed action schema, title bounds, and ISO due date.
enum RemindersTool {
    static let name = "reminders_list"
    private static let store = EKEventStore()

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "List incomplete reminders from Apple Reminders. Creating, completing, and deleting reminders are handled directly from explicit user commands.",
            "parameters": [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        ]
    ]]

    struct Call: Equatable {
        let id: String
        let rawArguments: String
    }

    enum Command: Equatable {
        case create(title: String, dueDate: Date?)
        case list
        case complete(String)
        case delete(String)
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case accessDenied
        case noDefaultList
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .malformedArguments: return "Rosy produced an invalid Reminders request."
            case .accessDenied: return "Rosy Bit needs Reminders permission for that. You can enable it in System Settings → Privacy & Security → Reminders."
            case .noDefaultList: return "Apple Reminders does not have a default list available."
            case .saveFailed: return "Apple Reminders could not save that change."
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        let raw = arguments.isEmpty ? "{}" : arguments
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.isEmpty else { throw ToolError.malformedArguments }
        return Call(id: id?.isEmpty == false ? id! : "reminders-list-call", rawArguments: raw)
    }

    static func explicitCommand(in message: String, now: Date = Date()) -> Command? {
        guard let prompt = singleLine(message) else { return nil }
        if matches(prompt, #"^(?:please\s+)?(?:list|show)\s+(?:my\s+)?reminders(?:,?\s+please)?[?!.]*$"#)
            || matches(prompt, #"^(?:please\s+)?what\s+(?:are\s+)?my\s+reminders(?:,?\s+please)?[?!.]*$"#) {
            return .list
        }
        if let title = capture(prompt, #"^(?:please\s+)?(?:complete|finish|mark\s+(?:as\s+)?done)\s+(?:the\s+)?(?:reminder\s+)?[\"']?(.+?)[\"']?(?:,?\s+please)?[?!.]*$"#) {
            return clean(title).isEmpty ? nil : .complete(clean(title))
        }
        if let title = capture(prompt, #"^(?:please\s+)?(?:delete|remove)\s+(?:the\s+)?(?:reminder\s+)?[\"']?(.+?)[\"']?(?:,?\s+please)?[?!.]*$"#) {
            return clean(title).isEmpty ? nil : .delete(clean(title))
        }
        let createPatterns = [
            #"^(?:please\s+)?remind\s+me\s+to\s+(.+?)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?(?:add|create)\s+(?:a\s+)?reminder\s+(?:to|for)\s+(.+?)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?add\s+[\"']?(.+?)[\"']?\s+to\s+(?:my\s+)?reminders(?:,?\s+please)?[?!.]*$"#,
        ]
        for pattern in createPatterns {
            guard let captured = capture(prompt, pattern) else { continue }
            let parsed = titleAndDate(from: clean(captured), now: now)
            guard !parsed.title.isEmpty else { return nil }
            return .create(title: parsed.title, dueDate: parsed.date)
        }
        return nil
    }

    @MainActor
    static func execute(_ command: Command) async throws -> String {
        try await ensureAccess()
        switch command {
        case .create(let title, let dueDate):
            guard let calendar = store.defaultCalendarForNewReminders() else { throw ToolError.noDefaultList }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = calendar
            if let dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: dueDate)
            }
            do { try store.save(reminder, commit: true) } catch { throw ToolError.saveFailed }
            let due = dueDate.map { " for **\(dateDescription($0))**" } ?? ""
            return "Added **\(title)** to Reminders\(due)."

        case .list:
            return try await listResult()

        case .complete(let title):
            let matches = try await matching(title)
            guard !matches.isEmpty else { return "I couldn't find an incomplete reminder matching **\(title)**." }
            guard matches.count == 1 else { return ambiguity(matches, action: "complete") }
            matches[0].isCompleted = true
            matches[0].completionDate = Date()
            do { try store.save(matches[0], commit: true) } catch { throw ToolError.saveFailed }
            return "Completed **\(matches[0].title ?? title)**."

        case .delete(let title):
            let matches = try await matching(title)
            guard !matches.isEmpty else { return "I couldn't find an incomplete reminder matching **\(title)**." }
            guard matches.count == 1 else { return ambiguity(matches, action: "delete") }
            do { try store.remove(matches[0], commit: true) } catch { throw ToolError.saveFailed }
            return "Deleted **\(matches[0].title ?? title)** from Reminders."
        }
    }

    @MainActor
    static func observation() async throws -> String {
        "Authoritative Apple Reminders list:\n\((try await listResult()).replacingOccurrences(of: "**", with: ""))"
    }

    @MainActor
    private static func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess: return
        case .denied, .restricted, .writeOnly: throw ToolError.accessDenied
        case .notDetermined:
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await withCheckedThrowingContinuation { continuation in
                    store.requestAccess(to: .reminder) { allowed, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: allowed) }
                    }
                }
            }
            guard granted else { throw ToolError.accessDenied }
        @unknown default: throw ToolError.accessDenied
        }
    }

    @MainActor
    private static func incomplete() async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    @MainActor
    private static func matching(_ query: String) async throws -> [EKReminder] {
        let all = await incomplete()
        let exact = all.filter { $0.title?.localizedCaseInsensitiveCompare(query) == .orderedSame }
        if !exact.isEmpty { return exact }
        return all.filter { $0.title?.localizedCaseInsensitiveContains(query) == true }
    }

    @MainActor
    private static func listResult() async throws -> String {
        let reminders = await incomplete().sorted {
            ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
        }.prefix(20)
        guard !reminders.isEmpty else { return "There are no incomplete reminders." }
        return "Incomplete reminders:\n" + reminders.map { reminder in
            let due = reminder.dueDateComponents?.date.map { " — \(dateDescription($0))" } ?? ""
            return "- **\(reminder.title ?? "Untitled reminder")**\(due)"
        }.joined(separator: "\n")
    }

    private static func ambiguity(_ reminders: [EKReminder], action: String) -> String {
        "More than one reminder matches; tell me which one to \(action):\n"
            + reminders.prefix(8).map { "- \($0.title ?? "Untitled reminder")" }.joined(separator: "\n")
    }

    private static func titleAndDate(from text: String, now: Date) -> (title: String, date: Date?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return (text, nil)
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let date = match.date,
              let swiftRange = Range(match.range, in: text) else { return (text, nil) }
        var title = text
        title.removeSubrange(swiftRange)
        title = title.replacingOccurrences(
            of: #"(?i)\s+(?:at|on|by|for)\s*$"#, with: "", options: .regularExpression)
        return (clean(title), date)
    }

    private static func dateDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
