import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelStore.shared.refresh()
        LoginItemModel.shared.registerOnFirstRun()
        ServerController.shared.start()

        // Gotcha #4: this is the only status refresh in the app, and it fires
        // when a menu opens rather than on a timer. Waking a fanless machine
        // every few seconds to poll /health is exactly what drains the battery.
        // In an LSUIElement app the only menu that can open is ours.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            ModelStore.shared.refresh()
            LoginItemModel.shared.refresh()
            ServerController.shared.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let menuObserver {
            NotificationCenter.default.removeObserver(menuObserver)
            self.menuObserver = nil
        }
        // Gotcha #1, first half: never leave llama-server holding the port.
        ServerController.shared.terminateSynchronously()
    }
}
