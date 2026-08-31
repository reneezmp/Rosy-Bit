import AudioToolbox
import CoreAudio
import Foundation

/// Narrow native access to the Mac's output volume.
///
/// The model-facing schema remains read-only. State changes are available only
/// through deterministic parsing of the user's own one-line command, so no
/// probabilistic argument is ever executed.
enum VolumeTool {
    static let name = "volume_get"

    static let schema: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": name,
            "description": "Read the Mac's current system output volume as a percentage. Use this when the user asks how loud the Mac is or what its current volume is.",
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
        case set(Int)
        case mute(Bool)
        case rejectedLevel(String)
        case needsExactLevel
    }

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case invalidLevel
        case unavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .malformedArguments:
                return "Rosy produced an invalid volume request."
            case .invalidLevel:
                return "Volume must be a whole percentage from 0 to 100."
            case .unavailable:
                return "The current output device does not expose its volume to Core Audio."
            }
        }
    }

    static func parse(id: String?, arguments: String) throws -> Call {
        let raw = arguments.isEmpty ? "{}" : arguments
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.isEmpty else {
            throw ToolError.malformedArguments
        }
        return Call(
            id: (id?.isEmpty == false ? id! : "volume-call"),
            rawArguments: raw)
    }

    /// Recognises only explicit, single-line commands. Vague relative requests
    /// remain ordinary conversation and cannot mutate the Mac.
    static func explicitCommand(in message: String) -> Command? {
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("[Timestamp:") == true {
            lines.removeFirst()
        }
        guard lines.count == 1 else { return nil }
        let prompt = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)

        let setPatterns = [
            #"^(?:please\s+)?(?:set|put|turn)\s+(?:the\s+)?(?:(?:audio|system|output)\s+)?volume(?:\s+(?:up|down))?\s+(?:to|at)\s+(-?[0-9]+(?:\.[0-9]+)?)\s*(?:%|percent)?(?:,?\s+please)?[.!]?$"#,
            #"^(?:please\s+)?(?:raise|lower)\s+(?:the\s+)?(?:(?:audio|system|output)\s+)?volume\s+to\s+(-?[0-9]+(?:\.[0-9]+)?)\s*(?:%|percent)?(?:,?\s+please)?[.!]?$"#,
        ]
        for pattern in setPatterns {
            guard let value = firstCapture(in: prompt, pattern: pattern) else { continue }
            guard let level = Int(value), (0...100).contains(level) else {
                return .rejectedLevel(value)
            }
            return .set(level)
        }

        if matches(
            prompt,
            pattern: #"^(?:please\s+)?unmute(?:\s+(?:(?:the|my)\s+)?(?:mac|computer|system|audio|sound|output|volume))?(?:,?\s+please)?[.!]?$"#) {
            return .mute(false)
        }
        if matches(
            prompt,
            pattern: #"^(?:please\s+)?(?:mute|silence)(?:\s+(?:(?:the|my)\s+)?(?:mac|computer|system|audio|sound|output|volume))?(?:,?\s+please)?[.!]?$"#) {
            return .mute(true)
        }
        let relativePatterns = [
            #"^(?:please\s+)?make\s+it\s+(?:louder|quieter|softer)(?:,?\s+please)?[.!]?$"#,
            #"^(?:please\s+)?turn\s+(?:it|the\s+(?:(?:audio|system|output)\s+)?volume)\s+(?:up|down)(?:\s+a\s+(?:bit|little))?(?:,?\s+please)?[.!]?$"#,
            #"^(?:please\s+)?(?:raise|lower|increase|decrease)\s+(?:the\s+)?(?:(?:audio|system|output)\s+)?volume(?:\s+a\s+(?:bit|little))?(?:,?\s+please)?[.!]?$"#,
        ]
        if relativePatterns.contains(where: { matches(prompt, pattern: $0) }) {
            return .needsExactLevel
        }
        return nil
    }

    static func execute(_ command: Command) throws -> String {
        switch command {
        case .set(let requested):
            let actual = try setOutputPercentage(requested)
            return "Volume set to **\(actual)%**. 🔊"
        case .mute(true):
            try setOutputMuted(true)
            return "Audio muted. 🔇"
        case .mute(false):
            try setOutputMuted(false)
            return "Audio unmuted. 🔊"
        case .rejectedLevel(let value):
            return "I can set the volume only to a whole percentage from **0% to 100%**; **\(value)%** is outside that range."
        case .needsExactLevel:
            return "Tell me the exact volume you want, from **0% to 100%**."
        }
    }

    static func currentOutputPercentage() throws -> Int {
        let device = try defaultOutputDevice()
        var volumeAddress = outputProperty(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &volumeAddress) else {
            throw ToolError.unavailable(kAudioHardwareUnknownPropertyError)
        }

        var scalar = Float32(0)
        var scalarSize = UInt32(MemoryLayout<Float32>.size)
        let volumeStatus = AudioObjectGetPropertyData(
            device,
            &volumeAddress,
            0,
            nil,
            &scalarSize,
            &scalar)
        guard volumeStatus == noErr, scalar.isFinite else {
            throw ToolError.unavailable(volumeStatus)
        }
        return percentage(from: scalar)
    }

    @discardableResult
    static func setOutputPercentage(_ level: Int) throws -> Int {
        guard (0...100).contains(level) else { throw ToolError.invalidLevel }
        let device = try defaultOutputDevice()
        var volumeAddress = outputProperty(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &volumeAddress) else {
            throw ToolError.unavailable(kAudioHardwareUnknownPropertyError)
        }

        var scalar = Float32(level) / 100
        let status = AudioObjectSetPropertyData(
            device,
            &volumeAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &scalar)
        guard status == noErr else { throw ToolError.unavailable(status) }

        // A direct level is ordinarily understood to make sound audible.
        // Devices without a mute property still accept the volume itself.
        if level > 0 { try? setOutputMuted(false) }
        return try currentOutputPercentage()
    }

    static func currentOutputMuted() throws -> Bool {
        let device = try defaultOutputDevice()
        for element in muteElements {
            var address = outputProperty(
                selector: kAudioDevicePropertyMute,
                element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(
                device, &address, 0, nil, &size, &value)
            guard status == noErr else { throw ToolError.unavailable(status) }
            return value != 0
        }
        throw ToolError.unavailable(kAudioHardwareUnknownPropertyError)
    }

    static func setOutputMuted(_ muted: Bool) throws {
        let device = try defaultOutputDevice()
        var changedAny = false
        for element in muteElements {
            var address = outputProperty(
                selector: kAudioDevicePropertyMute,
                element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value)
            guard status == noErr else { throw ToolError.unavailable(status) }
            changedAny = true
            // A main control already covers its output channels.
            if element == kAudioObjectPropertyElementMain { break }
        }
        guard changedAny else {
            throw ToolError.unavailable(kAudioHardwareUnknownPropertyError)
        }
    }

    private static let muteElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2
    ]

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutput,
            0,
            nil,
            &deviceSize,
            &device)
        guard deviceStatus == noErr else { throw ToolError.unavailable(deviceStatus) }
        return device
    }

    private static func outputProperty(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    static func percentage(from scalar: Float32) -> Int {
        Int((min(max(scalar, 0), 1) * 100).rounded())
    }

    static func observation(percentage: Int) -> String {
        "Core Audio reports the current system output volume as \(percentage)%. Tell the user this value plainly."
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        firstMatch(in: text, pattern: pattern) != nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let match = firstMatch(in: text, pattern: pattern),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func firstMatch(
        in text: String,
        pattern: String
    ) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]) else { return nil }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}
