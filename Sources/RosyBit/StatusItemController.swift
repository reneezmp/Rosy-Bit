import AppKit
import Combine
import QuartzCore

/// The menu bar item, in AppKit rather than SwiftUI's `MenuBarExtra`.
///
/// The reason is the activity dot. A menu bar icon has to be a *template*
/// image so macOS can tint it for light and dark and invert it while the menu
/// is open — and a template image is monochrome by definition, so the colour
/// cannot live in the icon. The way round it, which is what Osaurus does, is to
/// leave the image a template and add the dot as a sibling `NSView` on the
/// status bar button, where its layer keeps its own colour.
///
/// `MenuBarExtra` never exposes its `NSStatusItem`, so there is nowhere to put
/// that subview: a coloured shape inside its label is flattened away with the
/// rest of the template. Hence AppKit. `NSMenuDelegate` also gives an exact
/// menu-open hook, which is better than the app-wide notification it replaces.
final class StatusItemController: NSObject, NSMenuDelegate {

    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var activityDot: NSView?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    // MARK: - Installation

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.image = Self.sakuraTemplateImage()
            button.toolTip = "Rosy Bit"
            activityDot = Self.makeActivityDot(in: button)
        }

        let menu = NSMenu()
        menu.delegate = self
        // Validate nothing automatically: the status line is deliberately a
        // disabled item, and everything else is enabled by construction.
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        // The dot has to track inference without the menu being open, so this
        // is the one thing that cannot wait for `menuWillOpen`. It is still not
        // a timer — it fires only when llama-server actually says something.
        ServerController.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncActivityDot() }
            .store(in: &cancellables)

        syncActivityDot()
    }

    // MARK: - Activity dot

    private func syncActivityDot() {
        setActivity(ServerController.shared.activeRequests > 0)
    }

    private func setActivity(_ active: Bool) {
        guard let dot = activityDot, let layer = dot.layer else { return }

        guard active else {
            layer.removeAnimation(forKey: Self.blinkKey)
            dot.isHidden = true
            return
        }

        dot.isHidden = false
        guard layer.animation(forKey: Self.blinkKey) == nil else { return }

        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.2
        blink.duration = 0.8
        blink.autoreverses = true
        blink.repeatCount = .infinity
        layer.add(blink, forKey: Self.blinkKey)
    }

    private static let blinkKey = "blink"

    /// A small circular overlay pinned to the corner of the status button. It
    /// deliberately sits *on* the sakura, badge-style, with a light ring so it
    /// stays legible against the glyph in either appearance.
    private static func makeActivityDot(in button: NSStatusBarButton) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        button.addSubview(dot)

        let side: CGFloat = 7
        let inset: CGFloat = 3
        NSLayoutConstraint.activate([
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -inset),
            dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -inset),
            dot.widthAnchor.constraint(equalToConstant: side),
            dot.heightAnchor.constraint(equalToConstant: side),
        ])

        if let layer = dot.layer {
            layer.backgroundColor = NSColor.systemGreen.cgColor
            layer.cornerRadius = side / 2
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        }
        return dot
    }

    // MARK: - Icon

    /// Monochrome template image: macOS tints it to match the menu bar and the
    /// current appearance, and inverts it while the menu is open. The rosy
    /// colour lives on the app icon instead — same sakura, two assets.
    private static func sakuraTemplateImage() -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize)
        var didAddRepresentation = false

        for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            // Both files claim the same 18×18 point size while keeping their
            // native pixel dimensions, which is what marks the 36px file as @2x.
            representation.size = pointSize
            image.addRepresentation(representation)
            didAddRepresentation = true
        }

        guard didAddRepresentation else {
            // The app should never fail to appear just because art is missing.
            let fallback = NSImage(
                systemSymbolName: "camera.macro", accessibilityDescription: "Rosy Bit")
                ?? NSImage(size: pointSize)
            fallback.isTemplate = true
            return fallback
        }

        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        // Gotcha #4: the only status refresh in the app, and it happens when
        // the user actually looks at the menu rather than on a timer.
        ModelStore.shared.refresh()
        LoginItemModel.shared.refresh()
        ServerController.shared.refreshStatus()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(modelMenuItem())
        if ServerController.shared.canCancelRequests {
            menu.addItem(item("Cancel Request", #selector(cancelRequests)))
        }
        menu.addItem(item(
            ServerController.shared.state.isBusy ? "Stop Server" : "Start Server",
            #selector(toggleServer)))
        if Config.askBarEnabled {
            let ask = item("Ask…", #selector(showAskBar))
            // The global shortcut is registered separately in Carbon; this
            // mirrors the same current combination while Rosy Bit is frontmost.
            ask.keyEquivalent = Self.menuKeyEquivalent(for: Config.hotKeyCode)
            ask.keyEquivalentModifierMask = Self.menuModifiers(
                fromCarbonMask: Config.hotKeyModifiers)
            menu.addItem(ask)
        }
        menu.addItem(item("Copy Endpoint URL", #selector(copyEndpoint)))
        if Config.insightsEnabled {
            let captured = InsightsStore.shared.records.count
            let title = captured > 0 ? "Insights… (\(captured))" : "Insights…"
            menu.addItem(item(title, #selector(showInsights)))
        }
        menu.addItem(item("Open Log", #selector(openLog)))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))

        let login = item("Launch at Login", #selector(toggleLoginItem))
        login.state = LoginItemModel.shared.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(item("Quit Rosy Bit", #selector(quit), key: "q"))
    }

    /// Same information the activity dot carries, spelled out for anyone who
    /// opened the menu to find out what the machine is busy with.
    private var statusLine: String {
        let server = ServerController.shared
        guard server.state == .running, server.activeRequests > 0 else {
            return server.state.menuTitle
        }
        let plural = server.activeRequests == 1 ? "" : "s"
        return "◐ Working — \(server.activeRequests) request\(plural)"
    }

    private func modelMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let models = ModelStore.shared.models
        if models.isEmpty {
            let empty = NSMenuItem(title: "No .gguf files found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            submenu.addItem(item("Download a Model…", #selector(showModelSetup)))
        } else {
            for url in models {
                let entry = item(
                    ModelStore.menuTitle(for: url), #selector(selectModel(_:)))
                entry.representedObject = url
                entry.state = ModelStore.shared.isSelected(url) ? .on : .off
                submenu.addItem(entry)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(downloadMenuItem())
        submenu.addItem(item("Open Models Folder…", #selector(openModelsFolder)))
        parent.submenu = submenu
        return parent
    }

    /// The other Bonsai sizes, fetched on demand. Already-installed ones are
    /// disabled rather than hidden, so the menu shows the whole family and
    /// which of it is here.
    private func downloadMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Download", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let installed = ModelStore.shared.models.map { $0.lastPathComponent }
        for model in Config.knownModels {
            let present = installed.contains {
                $0.localizedCaseInsensitiveContains(model.filenameHint)
            }
            let title = present
                ? "\(model.name) — installed"
                : "\(model.name) — \(model.approximateSize)"

            let entry = item(title, #selector(downloadModel(_:)))
            entry.representedObject = model.repository
            entry.isEnabled = !present && !ModelDownloader.shared.state.isBusy
            submenu.addItem(entry)
        }

        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = true
        return entry
    }

    private static func menuKeyEquivalent(for keyCode: Int) -> String {
        switch keyCode {
        case 49: return " "
        case 36: return "\r"
        case 44: return "/"
        case 11: return "b"
        case 38: return "j"
        case 40: return "k"
        case 15: return "r"
        default: return ""
        }
    }

    private static func menuModifiers(fromCarbonMask mask: Int) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if mask & 256 != 0 { modifiers.insert(.command) }
        if mask & 512 != 0 { modifiers.insert(.shift) }
        if mask & 2048 != 0 { modifiers.insert(.option) }
        if mask & 4096 != 0 { modifiers.insert(.control) }
        return modifiers
    }

    // MARK: - Actions

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }

        let changed = !ModelStore.shared.isSelected(url)
        ModelStore.shared.select(url)
        guard changed else { return }

        // Switching models while serving should hand back a working endpoint;
        // switching while stopped should not start the server behind the user's
        // back, unless there was nothing to run before.
        let server = ServerController.shared
        if server.state.isBusy {
            server.restart()
        } else if server.state == .noModel {
            server.start()
        }
    }

    @objc private func toggleServer() {
        ServerController.shared.toggle()
    }

    @objc private func cancelRequests() {
        ServerController.shared.cancelActiveRequests()
    }

    @objc private func copyEndpoint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Config.endpointURL, forType: .string)
    }

    @objc private func openLog() {
        let url = Config.logFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }

    @objc private func showInsights() {
        InsightsWindowController.shared.show()
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openModelsFolder() {
        ModelStore.shared.revealModelFolder()
    }

    @objc private func showAskBar() {
        AskBarWindowController.shared.show()
    }

    @objc private func showModelSetup() {
        ModelSetupWindowController.shared.show()
    }

    @objc private func downloadModel(_ sender: NSMenuItem) {
        guard let repository = sender.representedObject as? String else { return }
        ModelSetupWindowController.shared.show()
        ModelDownloader.shared.start(repository: repository)
    }

    @objc private func toggleLoginItem() {
        LoginItemModel.shared.setEnabled(!LoginItemModel.shared.isEnabled)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
