import SwiftUI

@main
struct RosyBitApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item is the entire interface, and it is built in AppKit
        // by StatusItemController — see the note there for why it is not a
        // MenuBarExtra. `App` still requires a scene, and an empty Settings
        // scene is the inert one: with LSUIElement there is no app menu to open
        // it from, so nothing shows unless it is opened deliberately. It is
        // also where the settings window will go when that lands.
        Settings {
            EmptyView()
        }
    }
}
