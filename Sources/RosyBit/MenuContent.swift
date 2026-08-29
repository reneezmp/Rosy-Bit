import AppKit
import SwiftUI

/// The entire interface. Deliberately the default `.menu` style rather than
/// `.menuBarExtraStyle(.window)` — `MenuBarExtra` was new in macOS 13 and the
/// early rough edges were in the window style. A short menu does not need it.
struct MenuContent: View {

    @ObservedObject private var server = ServerController.shared
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var login = LoginItemModel.shared

    var body: some View {
        Text(server.state.menuTitle)

        Divider()

        modelMenu

        Button(server.state.isBusy ? "Stop Server" : "Start Server") {
            server.toggle()
        }

        Button("Copy Endpoint URL") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(Config.endpointURL, forType: .string)
        }

        Button("Open Log") {
            openLog()
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { login.isEnabled },
            set: { login.setEnabled($0) }
        ))

        Button("Quit Rosy Bit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu("Model") {
            if models.models.isEmpty {
                Text("No .gguf files found")
            } else {
                ForEach(models.models, id: \.self) { url in
                    Toggle(url.deletingPathExtension().lastPathComponent, isOn: Binding(
                        get: { models.isSelected(url) },
                        set: { isOn in if isOn { select(url) } }
                    ))
                }
            }

            Divider()

            Button("Open Models Folder…") {
                models.revealModelFolder()
            }
        }
    }

    private func select(_ url: URL) {
        guard !models.isSelected(url) else { return }
        models.select(url)

        // Switching models while serving should hand back a working endpoint;
        // switching while stopped should not start the server behind the user's
        // back, unless there was nothing to run before.
        if server.state.isBusy {
            server.restart()
        } else if server.state == .noModel {
            server.start()
        }
    }

    private func openLog() {
        let url = Config.logFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }
}
