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

    /// The C callback cannot capture context, so registered actions are kept
    /// here and looked up by the id the event carries.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// `keyCode` is a virtual key code (`kVK_Space` and friends); `modifiers`
    /// are Carbon masks (`optionKey`, `cmdKey`, …), not `NSEvent` ones.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installDispatcherIfNeeded()

        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        var hotKeyID = EventHotKeyID(signature: OSType(0x5242_5954), id: identifier)  // 'RBYT'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

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
