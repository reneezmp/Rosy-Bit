import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelStore.shared.refresh()
        LoginItemModel.shared.registerOnFirstRun()
        StatusItemController.shared.install()

        // A downloaded model should be usable immediately rather than after a
        // restart, so picking it up is wired here rather than left to the next
        // menu open.
        ModelDownloader.shared.onInstalled = { _ in
            ModelStore.shared.refresh()
            ModelSetupWindowController.shared.closeIfOpen()
            ServerController.shared.start()
        }

        if ModelStore.shared.models.isEmpty {
            // Nothing to serve. Offer to fetch one instead of just reporting
            // the problem in the menu and leaving the user to find a script.
            ModelSetupWindowController.shared.show()
        }
        ServerController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Gotcha #1, first half: never leave llama-server holding the port.
        ServerController.shared.terminateSynchronously()
    }
}
