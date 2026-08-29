import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelStore.shared.refresh()
        LoginItemModel.shared.registerOnFirstRun()
        StatusItemController.shared.install()
        ServerController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Gotcha #1, first half: never leave llama-server holding the port.
        ServerController.shared.terminateSynchronously()
    }
}
