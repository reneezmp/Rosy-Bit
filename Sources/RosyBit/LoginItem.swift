import Combine
import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp`, the macOS 13 replacement for login item
/// helpers. Registering requires the app to sit somewhere stable — put it in
/// `/Applications` before turning this on.
final class LoginItemModel: ObservableObject {

    static let shared = LoginItemModel()

    private static let firstRunKey = "didRegisterLoginItem"

    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    func refresh() {
        let enabled = SMAppService.mainApp.status == .enabled
        if isEnabled != enabled {
            isEnabled = enabled
        }
    }

    /// Rosy Bit is meant to be always-on, so it registers itself the first time
    /// it launches. After that the menu toggle is authoritative — if the user
    /// switches it off, it stays off across restarts.
    func registerOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.firstRunKey) else {
            refresh()
            return
        }
        UserDefaults.standard.set(true, forKey: Self.firstRunKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSLog("Rosy Bit: could not change login item: %@", error.localizedDescription)
        }
        refresh()
    }
}
