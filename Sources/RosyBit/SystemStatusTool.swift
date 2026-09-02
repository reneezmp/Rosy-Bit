import Foundation
import IOKit.ps

/// Read-only facts obtained from native macOS APIs. Nothing polls in the
/// background; Rosy samples exactly one requested metric and stops.
enum SystemStatusTool {
    static let name = "system_get"

    enum Metric: String, CaseIterable {
        case battery
        case powerSource = "power_source"
        case storage
        case memory
    }

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "Read one current fact about this Mac: battery level and charging state, power source, free storage, or installed memory.",
            "parameters": [
                "type": "object",
                "properties": [
                    "metric": [
                        "type": "string",
                        "enum": Metric.allCases.map(\.rawValue),
                        "description": "The single system fact to read."
                    ]
                ],
                "required": ["metric"],
                "additionalProperties": false
            ]
        ]
    ]]

    struct Call: Equatable {
        let id: String
        let metric: Metric
        let rawArguments: String
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .malformedArguments:
                return "Rosy produced an invalid system-status request."
            case .unavailable(let detail):
                return detail
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["metric"],
              let rawMetric = object["metric"] as? String,
              let metric = Metric(rawValue: rawMetric) else {
            throw ToolError.malformedArguments
        }
        return Call(
            id: id?.isEmpty == false ? id! : "system-status-call",
            metric: metric,
            rawArguments: arguments)
    }

    static func routedCall(metric: Metric) -> Call {
        let data = try? JSONSerialization.data(withJSONObject: ["metric": metric.rawValue])
        let arguments = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Call(id: "system-status-route", metric: metric, rawArguments: arguments)
    }

    static func explicitMetric(in message: String) -> Metric? {
        guard let prompt = singleUserLine(message)?.lowercased() else { return nil }
        let trimmed = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!.")))
        let groups: [(Metric, [String])] = [
            (.battery, [
                #"^(?:what(?:'s| is) )?(?:my |the |this mac'?s? )?battery (?:level|percentage|percent|status)$"#,
                #"^(?:how much battery|how much battery life) (?:do i have|is left|remains)$"#,
                #"^(?:is|am) (?:my mac|the mac|it|i) charging$"#,
            ]),
            (.powerSource, [
                #"^(?:what(?:'s| is) )?(?:my |the |this mac'?s? )?power source$"#,
                #"^(?:am i|is (?:my mac|the mac|it)) (?:plugged in|on battery(?: power)?|on ac(?: power)?)$"#,
            ]),
            (.storage, [
                #"^(?:how much|what amount of) (?:free |available )?(?:disk space|storage)(?: (?:do i have|is left|remains))?$"#,
                #"^(?:what(?:'s| is) )?(?:my |the |this mac'?s? )?(?:free |available )?(?:disk space|storage)$"#,
            ]),
            (.memory, [
                #"^(?:how much|what amount of) (?:ram|memory)(?: (?:does (?:my|this|the) mac have|is installed))?$"#,
                #"^(?:what(?:'s| is) )?(?:my |the |this mac'?s? )?(?:installed )?(?:ram|memory)$"#,
            ]),
        ]
        for (metric, patterns) in groups where patterns.contains(where: {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) { return metric }
        return nil
    }

    static func result(for metric: Metric) throws -> String {
        switch metric {
        case .battery:
            let battery = try batteryStatus()
            let state = battery.isCharging ? "charging" : "not charging"
            return "Battery is **\(battery.percentage)%** and is **\(state)**."
        case .powerSource:
            let source = try powerSource()
            return "The Mac is currently using **\(source)**."
        case .storage:
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            guard let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
                  let total = (attributes[.systemSize] as? NSNumber)?.int64Value else {
                throw ToolError.unavailable("macOS did not report the startup disk's capacity.")
            }
            return "The startup disk has **\(bytes(free)) free** out of **\(bytes(total))**."
        case .memory:
            return "This Mac has **\(bytes(Int64(ProcessInfo.processInfo.physicalMemory)))** of physical memory."
        }
    }

    static func observation(metric: Metric, result: String) -> String {
        "Authoritative native macOS \(metric.rawValue) reading: \(result.replacingOccurrences(of: "**", with: ""))"
    }

    private struct BatteryStatus {
        let percentage: Int
        let isCharging: Bool
    }

    private static func batteryStatus() throws -> BatteryStatus {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let unmanaged = IOPSGetPowerSourceDescription(snapshot, source) else { continue }
            let description = unmanaged.takeUnretainedValue() as NSDictionary
            guard let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            let percentage = Int((current.doubleValue / maximum.doubleValue * 100).rounded())
            let charging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            return BatteryStatus(percentage: max(0, min(100, percentage)), isCharging: charging)
        }
        throw ToolError.unavailable("This Mac does not expose an internal battery through IOKit.")
    }

    private static func powerSource() throws -> String {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let unmanaged = IOPSGetProvidingPowerSourceType(snapshot) else {
            throw ToolError.unavailable("macOS did not report the current power source.")
        }
        let source = unmanaged.takeUnretainedValue() as String
        switch source {
        case kIOPMACPowerKey: return "AC power"
        case kIOPMBatteryPowerKey: return "battery power"
        case kIOPMUPSPowerKey: return "UPS power"
        default: return source
        }
    }

    private static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: count)
    }

    private static func singleUserLine(_ message: String) -> String? {
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("[Timestamp:") == true { lines.removeFirst() }
        guard lines.count == 1 else { return nil }
        return lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
