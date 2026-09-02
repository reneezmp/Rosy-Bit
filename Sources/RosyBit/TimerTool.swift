import Foundation
import UserNotifications

/// Timers are state-changing only through strict product-side grammar. The
/// Guided mode shows the model only a read-only list operation. Model-led may
/// supply a duration through its separate adapter, which reuses the same
/// duration bounds, notification permission, and cancellation semantics here.
enum TimerTool {
    static let name = "timer_list"
    static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60
    private static let defaultsKey = "rosyTimers"

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "List the timers currently scheduled by Rosy Bit. Creating and cancelling timers are handled directly from explicit user commands.",
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

    struct Record: Codable, Equatable {
        let id: String
        let label: String?
        let fireDate: Date
    }

    enum Command: Equatable {
        case create(duration: TimeInterval, label: String?)
        case rejectedDuration(String)
        case list
        case cancel(label: String?)
        case cancelAll
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case invalidDuration
        case notificationsDenied

        var errorDescription: String? {
            switch self {
            case .malformedArguments:
                return "Rosy produced an invalid timer request."
            case .invalidDuration:
                return "Timers must be between one second and seven days."
            case .notificationsDenied:
                return "Rosy Bit needs notification permission to alert you when a timer finishes."
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        let raw = arguments.isEmpty ? "{}" : arguments
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.isEmpty else { throw ToolError.malformedArguments }
        return Call(id: id?.isEmpty == false ? id! : "timer-list-call", rawArguments: raw)
    }

    static func explicitCommand(in message: String) -> Command? {
        guard let prompt = singleUserLine(message) else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if matches(trimmed, #"^(?:please\s+)?(?:list|show)\s+(?:my\s+)?timers(?:,?\s+please)?[?!.]*$"#)
            || matches(trimmed, #"^(?:please\s+)?what\s+timers\s+(?:are\s+)?(?:running|active|set)(?:,?\s+please)?[?!.]*$"#) {
            return .list
        }
        if matches(trimmed, #"^(?:please\s+)?(?:cancel|stop)\s+all\s+(?:my\s+)?timers(?:,?\s+please)?[?!.]*$"#) {
            return .cancelAll
        }
        if matches(trimmed, #"^(?:please\s+)?(?:cancel|stop)\s+(?:(?:my|the)\s+)?timer(?:,?\s+please)?[?!.]*$"#) {
            return .cancel(label: nil)
        }
        if let label = capture(
            trimmed,
            #"^(?:please\s+)?(?:cancel|stop)\s+(?:(?:my|the)\s+)?(.+?)\s+timer(?:,?\s+please)?[?!.]*$"#) {
            return .cancel(label: normalizedLabel(label))
        }

        let creationPatterns = [
            #"^(?:please\s+)?(?:set|start)\s+(?:a\s+)?timer\s+for\s+(.+?)(?:,?\s+please)?[?!.]*$"#,
            #"^(?:please\s+)?(?:set|start)\s+(?:a\s+)?(.+?)\s+timer\s+for\s+(.+?)(?:,?\s+please)?[?!.]*$"#,
        ]
        for (index, pattern) in creationPatterns.enumerated() {
            guard let captures = captures(trimmed, pattern),
                  let durationText = captures.last else { continue }
            guard let duration = duration(from: durationText) else {
                return .rejectedDuration(durationText)
            }
            let label = index == 1 ? captures.first.flatMap(normalizedLabel) : nil
            return .create(duration: duration, label: label)
        }
        return nil
    }

    static func execute(
        _ command: Command,
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current()
    ) async throws -> String {
        switch command {
        case .rejectedDuration:
            return "Timers must be between **one second** and **seven days**, using seconds, minutes, hours, or days."

        case .create(let duration, let label):
            guard duration >= 1, duration <= maximumDuration else {
                throw ToolError.invalidDuration
            }
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { throw ToolError.notificationsDenied }

            let record = Record(
                id: "rosy.timer.\(UUID().uuidString)",
                label: label,
                fireDate: Date().addingTimeInterval(duration))
            let content = UNMutableNotificationContent()
            content.title = label.map { "\($0.capitalized) timer" } ?? "Rosy Bit timer"
            content.body = label.map { "Your \($0) timer has finished." } ?? "Your timer has finished."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: record.id,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: duration,
                    repeats: false))
            try await center.add(request)
            var current = records(defaults: defaults)
            current.append(record)
            save(current, defaults: defaults)
            let name = label.map { " **\($0)**" } ?? ""
            return "Timer\(name) set for **\(durationDescription(duration))**. ⏲️"

        case .list:
            return listResult(defaults: defaults)

        case .cancelAll:
            let current = records(defaults: defaults)
            guard !current.isEmpty else { return "There are no active Rosy timers." }
            center.removePendingNotificationRequests(withIdentifiers: current.map(\.id))
            save([], defaults: defaults)
            return "Cancelled **\(current.count)** Rosy timer\(current.count == 1 ? "" : "s")."

        case .cancel(let label):
            let current = records(defaults: defaults)
            guard !current.isEmpty else { return "There are no active Rosy timers." }
            let matches: [Record]
            if let label {
                matches = current.filter {
                    $0.label?.localizedCaseInsensitiveCompare(label) == .orderedSame
                }
            } else {
                matches = current
            }
            guard !matches.isEmpty else {
                return "I couldn't find an active timer named **\(label ?? "that")**."
            }
            guard matches.count == 1 else {
                return "More than one timer matches. \(listResult(defaults: defaults))"
            }
            let match = matches[0]
            center.removePendingNotificationRequests(withIdentifiers: [match.id])
            save(current.filter { $0.id != match.id }, defaults: defaults)
            let name = match.label.map { " **\($0)**" } ?? ""
            return "Cancelled the\(name) timer."
        }
    }

    static func listResult(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> String {
        let active = records(now: now, defaults: defaults)
        guard !active.isEmpty else { return "There are no active Rosy timers." }
        let lines = active.sorted { $0.fireDate < $1.fireDate }.map { record in
            let remaining = max(1, record.fireDate.timeIntervalSince(now))
            let name = record.label.map { "**\($0)** — " } ?? ""
            return "- \(name)\(durationDescription(remaining)) remaining"
        }
        return "Active Rosy timers:\n" + lines.joined(separator: "\n")
    }

    static func observation(defaults: UserDefaults = .standard) -> String {
        "Authoritative local timer list:\n\(listResult(defaults: defaults).replacingOccurrences(of: "**", with: ""))"
    }

    static func records(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> [Record] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        let active = decoded.filter { $0.fireDate > now }
        if active != decoded { save(active, defaults: defaults) }
        return active
    }

    private static func save(_ records: [Record], defaults: UserDefaults) {
        if records.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private static func duration(from text: String) -> TimeInterval? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: " and ", with: " ")
        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?)"#,
            options: [.caseInsensitive]) else { return nil }
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, range: fullRange)
        guard !matches.isEmpty else { return nil }

        var covered = normalized
        for match in matches.reversed() {
            guard let range = Range(match.range, in: covered) else { return nil }
            covered.removeSubrange(range)
        }
        let residue = covered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard residue.isEmpty else { return nil }

        var total: TimeInterval = 0
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: normalized),
                  let unitRange = Range(match.range(at: 2), in: normalized),
                  let value = Double(normalized[valueRange]) else { return nil }
            let unit = normalized[unitRange]
            let multiplier: Double
            if unit.hasPrefix("sec") { multiplier = 1 }
            else if unit.hasPrefix("min") { multiplier = 60 }
            else if unit.hasPrefix("h") { multiplier = 3_600 }
            else { multiplier = 86_400 }
            total += value * multiplier
        }
        guard total.isFinite, total >= 1, total <= maximumDuration else { return nil }
        return total
    }

    private static func durationDescription(_ interval: TimeInterval) -> String {
        var seconds = max(1, Int(interval.rounded()))
        let days = seconds / 86_400; seconds %= 86_400
        let hours = seconds / 3_600; seconds %= 3_600
        let minutes = seconds / 60; seconds %= 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0, parts.count < 2 {
            parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        }
        return parts.prefix(2).joined(separator: " ")
    }

    private static func normalizedLabel(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                    .union(.whitespaces)
                    .union(CharacterSet(charactersIn: "-'’"))
                    .contains($0)
              }) else { return nil }
        return value
    }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { number in
            Range(match.range(at: number), in: text).map { String(text[$0]) }
        }
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        captures(text, pattern)?.first
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func singleUserLine(_ message: String) -> String? {
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("[Timestamp:") == true { lines.removeFirst() }
        guard lines.count == 1 else { return nil }
        return lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
