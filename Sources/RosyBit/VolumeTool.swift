import AudioToolbox
import CoreAudio
import Foundation

/// A read-only view of the Mac's current output volume.
///
/// Core Audio keeps this capability local and narrow. There is no shell,
/// accessibility automation, or permission to mutate the device hiding behind
/// the schema.
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

    enum ToolError: LocalizedError, Equatable {
        case malformedArguments
        case unavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .malformedArguments:
                return "Rosy produced an invalid volume request."
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

    static func currentOutputPercentage() throws -> Int {
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

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
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

    static func percentage(from scalar: Float32) -> Int {
        Int((min(max(scalar, 0), 1) * 100).rounded())
    }

    static func observation(percentage: Int) -> String {
        "Core Audio reports the current system output volume as \(percentage)%. Tell the user this value plainly."
    }
}
