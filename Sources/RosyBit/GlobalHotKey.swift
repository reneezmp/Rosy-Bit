import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`, which needs Accessibility permission —
/// a heavy first-run prompt for a convenience shortcut. This is the old API,
/// but it is what most menu bar apps actually use and it asks for nothing.
///
/// Also avoids a third-party package: the popular answer here is a dependency,
/// and this project has none.
final class GlobalHotKey {

    /// Carbon's virtual key codes and modifier masks, re-exposed so callers do
    /// not have to import Carbon themselves — containing it here is the whole
    /// point of this type.
    struct Modifiers: OptionSet {
        let rawValue: UInt32

        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
    }

    static let spaceKey = UInt32(kVK_Space)

    /// The C callback cannot capture context, so registered actions are kept
    /// here and looked up by the id the event carries.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// `keyCode` is a virtual key code — use `GlobalHotKey.spaceKey` and
    /// friends rather than importing Carbon at the call site.
    init?(keyCode: UInt32, modifiers: Modifiers, action: @escaping () -> Void) {
        Self.installDispatcherIfNeeded()

        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x5242_5954), id: identifier)  // 'RBYT'
        let status = RegisterEventHotKey(
            keyCode, modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        guard status == noErr, hotKeyRef != nil else { return nil }
        Self.actions[identifier] = action
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.actions[identifier] = nil
    }

    private static func installDispatcherIfNeeded() {
        guard eventHandler == nil else { return }

        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard status == noErr else { return status }

                let identifier = hotKeyID.id
                DispatchQueue.main.async { GlobalHotKey.actions[identifier]?() }
                return noErr
            },
            1,
            &specification,
            nil,
            &eventHandler)
    }
}
