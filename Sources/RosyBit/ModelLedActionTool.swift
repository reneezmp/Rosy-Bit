import CoreFoundation
import Foundation

/// Mutation schemas available only in Model-led routing. Every argument is
/// still parsed from a closed JSON shape and converted into the same native
/// commands used by Guided mode; routing freedom never bypasses validation.
enum ModelLedActionTool {
    static let volumeName = "volume_control"
    static let timerName = "timer_manage"
    static let appsFinderName = "apps_finder_control"
    static let remindersName = "reminders_manage"

    struct Result {
        let id: String
        let name: String
        let rawArguments: String
        let observation: String
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments

        var errorDescription: String? {
            "Rosy produced a model-led tool action with invalid or unsafe arguments."
        }
    }

    static func schemas(
        volumeEnabled: Bool,
        timersEnabled: Bool,
        appsFinderEnabled: Bool,
        remindersEnabled: Bool
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if volumeEnabled { result.append(volumeSchema) }
        if timersEnabled { result.append(timerSchema) }
        if appsFinderEnabled { result.append(appsFinderSchema) }
        if remindersEnabled { result.append(remindersSchema) }
        return result
    }

    static func execute(id: String?, name: String, arguments: String) async throws -> Result {
        let object = try dictionary(arguments)
        let callID = id?.isEmpty == false ? id! : "model-led-action"
        let response: String
        switch name {
        case volumeName:
            guard SkillSettings.isEnabled(.volumeControl),
                  let action = object["action"] as? String else { throw ToolError.malformedArguments }
            switch action {
            case "set":
                guard Set(object.keys) == ["action", "level"],
                      let level = exactInteger(object["level"]), (0...100).contains(level) else {
                    throw ToolError.malformedArguments
                }
                response = try VolumeTool.execute(.set(level))
            case "mute", "unmute":
                guard Set(object.keys) == ["action"] else { throw ToolError.malformedArguments }
                response = try VolumeTool.execute(.mute(action == "mute"))
            default: throw ToolError.malformedArguments
            }

        case timerName:
            guard SkillSettings.isEnabled(.timers),
                  let action = object["action"] as? String else { throw ToolError.malformedArguments }
            switch action {
            case "create":
                guard Set(object.keys).isSubset(of: ["action", "duration_seconds", "label"]),
                      Set(object.keys).isSuperset(of: ["action", "duration_seconds"]),
                      let duration = finiteDouble(object["duration_seconds"]),
                      duration >= 1, duration <= TimerTool.maximumDuration,
                      let label = optionalShortString(object["label"], maximum: 60) else {
                    throw ToolError.malformedArguments
                }
                response = try await TimerTool.execute(.create(duration: duration, label: label))
            case "cancel":
                guard Set(object.keys).isSubset(of: ["action", "label"]),
                      let label = optionalShortString(object["label"], maximum: 60) else {
                    throw ToolError.malformedArguments
                }
                response = try await TimerTool.execute(.cancel(label: label))
            case "cancel_all":
                guard Set(object.keys) == ["action"] else { throw ToolError.malformedArguments }
                response = try await TimerTool.execute(.cancelAll)
            default: throw ToolError.malformedArguments
            }

        case appsFinderName:
            guard SkillSettings.isEnabled(.appsFinder),
                  Set(object.keys) == ["action", "target"],
                  let action = object["action"] as? String,
                  let target = requiredShortString(object["target"], maximum: 1_024) else {
                throw ToolError.malformedArguments
            }
            let command: AppsFinderTool.Command
            switch action {
            case "open_app": command = .openApp(target)
            case "quit_app": command = .quitApp(target)
            case "reveal": command = .reveal(target)
            case "open_folder":
                guard let folder = AppsFinderTool.Folder(rawValue: target.lowercased()) else {
                    throw ToolError.malformedArguments
                }
                command = .openFolder(folder)
            default: throw ToolError.malformedArguments
            }
            response = try await AppsFinderTool.execute(command)

        case remindersName:
            guard SkillSettings.isEnabled(.reminders),
                  let action = object["action"] as? String else { throw ToolError.malformedArguments }
            switch action {
            case "create":
                guard Set(object.keys).isSubset(of: ["action", "title", "due_at"]),
                      Set(object.keys).isSuperset(of: ["action", "title"]),
                      let title = requiredShortString(object["title"], maximum: 240),
                      let dueDate = optionalISODate(object["due_at"]) else {
                    throw ToolError.malformedArguments
                }
                response = try await RemindersTool.execute(.create(title: title, dueDate: dueDate))
            case "complete", "delete":
                guard Set(object.keys) == ["action", "title"],
                      let title = requiredShortString(object["title"], maximum: 240) else {
                    throw ToolError.malformedArguments
                }
                response = try await RemindersTool.execute(
                    action == "complete" ? .complete(title) : .delete(title))
            default: throw ToolError.malformedArguments
            }
        default: throw ToolError.malformedArguments
        }
        return Result(
            id: callID,
            name: name,
            rawArguments: arguments,
            observation: "Authoritative native macOS action result: \(response.replacingOccurrences(of: "**", with: ""))")
    }

    private static let volumeSchema = schema(
        name: volumeName,
        description: "Set or mute Mac output volume. Use only when the user clearly requests the change.",
        properties: [
            "action": ["type": "string", "enum": ["set", "mute", "unmute"]],
            "level": ["type": "integer", "minimum": 0, "maximum": 100]
        ], required: ["action"])

    private static let timerSchema = schema(
        name: timerName,
        description: "Create or cancel Rosy timers. Durations are seconds and must reflect the user's request.",
        properties: [
            "action": ["type": "string", "enum": ["create", "cancel", "cancel_all"]],
            "duration_seconds": ["type": "number", "minimum": 1, "maximum": TimerTool.maximumDuration],
            "label": ["type": "string", "maxLength": 60]
        ], required: ["action"])

    private static let appsFinderSchema = schema(
        name: appsFinderName,
        description: "Open or quit an installed app, open a standard Finder folder, or reveal an existing path. Use only for an explicit user request.",
        properties: [
            "action": ["type": "string", "enum": ["open_app", "quit_app", "open_folder", "reveal"]],
            "target": ["type": "string", "description": "App name, existing path, or one of home, desktop, documents, downloads, applications."]
        ], required: ["action", "target"])

    private static let remindersSchema = schema(
        name: remindersName,
        description: "Create, complete, or delete an Apple Reminder when the user clearly requests it.",
        properties: [
            "action": ["type": "string", "enum": ["create", "complete", "delete"]],
            "title": ["type": "string", "maxLength": 240],
            "due_at": ["type": "string", "description": "Optional ISO 8601 due date with timezone."]
        ], required: ["action", "title"])

    private static func schema(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        ["type": "function", "function": [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object", "properties": properties,
                "required": required, "additionalProperties": false
            ]
        ]]
    }

    private static func dictionary(_ arguments: String) throws -> [String: Any] {
        guard arguments.count <= 4_096, let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.malformedArguments
        }
        return object
    }
    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }
    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    /// Returns `.some(nil)` for an omitted optional and `nil` for malformed.
    private static func optionalShortString(_ value: Any?, maximum: Int) -> String?? {
        guard let value else { return .some(nil) }
        guard let string = requiredShortString(value, maximum: maximum) else { return nil }
        return .some(string)
    }
    private static func requiredShortString(_ value: Any?, maximum: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, string.count <= maximum,
              !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return string
    }
    /// Returns `.some(nil)` when omitted and `nil` when present but invalid.
    private static func optionalISODate(_ value: Any?) -> Date?? {
        guard let value else { return .some(nil) }
        guard let raw = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }
        return .some(date)
    }
}
