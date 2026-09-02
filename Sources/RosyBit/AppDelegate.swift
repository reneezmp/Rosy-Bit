import AppKit
import Foundation
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Timers should still announce themselves while Rosy's menu or chat is
        // active; without a delegate macOS suppresses foreground presentation.
        UNUserNotificationCenter.current().delegate = self
        ModelStore.shared.refresh()
        LoginItemModel.shared.registerOnFirstRun()
        StatusItemController.shared.install()
        AskBarWindowController.shared.registerHotKey()

        // A downloaded model should be usable immediately rather than after a
        // restart, so picking it up is wired here rather than left to the next
        // menu open.
        ModelDownloader.shared.onInstalled = { _ in
            ModelStore.shared.refresh()
            ModelSetupWindowController.shared.closeIfOpen()
            // Installing a local model must not silently take inference back
            // from an explicitly selected cloud profile.
            if !CloudModelStore.shared.isCloudSelected {
                ServerController.shared.start()
            }
        }
        HuggingFaceModelImporter.shared.onInstalled = { url in
            ModelStore.shared.refresh()
            ModelStore.shared.select(url)
            HuggingFaceImportWindowController.shared.closeIfOpen()
            if !CloudModelStore.shared.isCloudSelected {
                let server = ServerController.shared
                if server.state.isBusy { server.restart() } else { server.start() }
            }
        }

        if ModelStore.shared.models.isEmpty && !CloudModelStore.shared.isCloudSelected {
            // Nothing to serve. Offer to fetch one instead of just reporting
            // the problem in the menu and leaving the user to find a script.
            ModelSetupWindowController.shared.show()
        }
        if !CloudModelStore.shared.isCloudSelected {
            ServerController.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Gotcha #1, first half: never leave llama-server holding the port.
        ServerController.shared.terminateSynchronously()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
