import AppKit
import Foundation
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()

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

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// Never drawn — the app is LSUIElement — but its key equivalents are
    /// dispatched to the key window, which is the only reason editing
    /// shortcuts work inside Rosy's text fields. Items carry no target so
    /// they travel the responder chain to whatever field is focused.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.openSettings),
            keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Rosy Bit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        return menu
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
