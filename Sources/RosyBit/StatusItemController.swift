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
    private var isMenuOpen = false
    /// The budget submenu that is actually on screen, which is not necessarily
    /// the one the most recent `rebuild` created. Set and cleared by that
    /// menu's own delegate callbacks, because nothing on `NSMenu` answers
    /// "are you open" and the alternatives all guess.
    private weak var openBudgetSubmenu: NSMenu?
    /// Identifies a budget submenu across rebuilds, which a reference to one
    /// particular `NSMenu` cannot do.
    private static let budgetMenuIdentifier =
        NSUserInterfaceItemIdentifier("com.rosybit.contextBudget")
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
            .sink { [weak self] _ in
                self?.syncActivityDot()
                // A server that has just come up can be asked what the prefix
                // costs, and one that has just gone down cannot. Cheap when
                // nothing changed: it compares a key and returns.
                Task { @MainActor in PrefixBudget.shared.refresh() }
            }
            .store(in: &cancellables)
        CloudModelStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncActivityDot() }
            .store(in: &cancellables)
        AppleModelStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncActivityDot() }
            .store(in: &cancellables)
        // The measurement arrives after the menu has already been built, so
        // the line would otherwise say "measuring…" until the next time the
        // menu was opened. Redrawing an open menu in place is what makes the
        // number appear where the user is already looking.
        PrefixBudget.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isMenuOpen else { return }
                // Rebuilding the whole menu would tear down the submenu the
                // reader is looking at, so an open budget is refilled in place.
                // Whether it is open comes from its delegate callbacks and not
                // from the state: the measurement lands with `isMeasuring`
                // already false and every row disabled, so neither that flag
                // nor `highlightedItem` can answer at the one moment it counts.
                if let submenu = self.openBudgetSubmenu {
                    self.populateBudget(submenu)
                    return
                }
                if let menu = self.statusItem?.menu { self.rebuild(menu) }
            }
            .store(in: &cancellables)

        syncActivityDot()
    }

    // MARK: - Activity dot

    private func syncActivityDot() {
        setActivity(
            ServerController.shared.activeRequests > 0
                || CloudModelStore.shared.activeRequests > 0
                || AppleModelStore.shared.activeRequests > 0)
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

    func menuDidClose(_ menu: NSMenu) {
        // By identifier rather than by reference. A redraw can replace the
        // budget submenu while the reader is still inside the old one, and an
        // identity check against the newest build would read that close as the
        // whole menu closing — silencing every redraw after it.
        guard menu.identifier != Self.budgetMenuIdentifier else {
            if menu === openBudgetSubmenu { openBudgetSubmenu = nil }
            return
        }
        isMenuOpen = false
        openBudgetSubmenu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        // The Context Budget submenu is the one place inference is invited.
        guard menu.identifier != Self.budgetMenuIdentifier else {
            openBudgetSubmenu = menu
            PrefixBudget.shared.measureOnDevice()
            populateBudget(menu)
            return
        }
        isMenuOpen = true
        // Nothing is displayed at the moment the root menu opens, and the
        // rebuild below replaces the budget submenu anyway.
        openBudgetSubmenu = nil
        // Gotcha #4: the only status refresh in the app, and it happens when
        // the user actually looks at the menu rather than on a timer.
        ModelStore.shared.refresh()
        LoginItemModel.shared.refresh()
        AppleModelStore.shared.refresh()
        ServerController.shared.refreshStatus()
        // Directly rather than through a `Task`: the "measuring…" state has to
        // be set before `rebuild` reads it, or the first open of a menu whose
        // prefix has changed shows a stale number instead of saying it is busy.
        PrefixBudget.shared.refresh()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(modelMenuItem())
        menu.addItem(skillsMenuItem())
        menu.addItem(contextBudgetMenuItem())
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
        menu.addItem(item("Chat…", #selector(showChat)))
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
        let apple = AppleModelStore.shared
        if apple.isSelected {
            if apple.activeRequests > 0 {
                return "◐ Working — Apple Intelligence"
            }
            return " Apple Intelligence — on-device"
        }
        let cloud = CloudModelStore.shared
        if cloud.isCloudSelected {
            if cloud.activeRequests > 0 {
                return "◐ Working — \(cloud.selectedDescription ?? "cloud model")"
            }
            return "☁ Cloud — \(cloud.selectedDescription ?? "not configured")"
        }
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
                entry.state = InferenceSource.current() == .local
                    && ModelStore.shared.isSelected(url) ? .on : .off
                submenu.addItem(entry)
            }
        }

        if let apple = appleModelMenuItem() {
            submenu.addItem(apple)
        }

        submenu.addItem(.separator())
        submenu.addItem(cloudModelsMenuItem())
        submenu.addItem(.separator())
        submenu.addItem(downloadMenuItem())
        submenu.addItem(item("Import from Hugging Face…", #selector(showHuggingFaceImport)))
        submenu.addItem(item("Open Models Folder…", #selector(openModelsFolder)))
        parent.submenu = submenu
        return parent
    }

    /// Apple's on-device model, listed among the local ones because that is
    /// what it is — nothing leaves the Mac.
    ///
    /// Absent entirely on hardware or an OS that cannot run it, which on the
    /// machine this app was written for is always. Present but disabled when
    /// this Mac could run it and something is merely switched off, because
    /// "why is it not here" is a worse question than a greyed-out line saying
    /// exactly what to turn on.
    private func appleModelMenuItem() -> NSMenuItem? {
        switch AppleFoundationModel.readiness {
        case .unsupported:
            return nil

        case .unavailable(let reason):
            let entry = NSMenuItem(
                title: AppleFoundationModel.title, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.toolTip = reason
            return entry

        case .available:
            let entry = item(AppleFoundationModel.title, #selector(selectAppleModel))
            entry.state = AppleModelStore.shared.isSelected ? .on : .off
            entry.toolTip = "Answers on this Mac, with no llama-server and no network."
            return entry
        }
    }

    private func cloudModelsMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Cloud Models", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let cloud = CloudModelStore.shared

        if let description = cloud.registeredDescription {
            let registered = item(description, #selector(selectCloudModel))
            registered.state = cloud.isCloudSelected ? .on : .off
            submenu.addItem(registered)
            submenu.addItem(.separator())
            submenu.addItem(item("Configure Cloud Model…", #selector(showCloudModel)))
        } else {
            submenu.addItem(item("Register Cloud Model…", #selector(showCloudModel)))
        }

        parent.submenu = submenu
        return parent
    }

    /// What Rosy's own requests cost before the question is typed.
    ///
    /// A short parent line, because the full figure with its denominator and
    /// percentage is far too long to sit in a menu beside "Open Log". The
    /// number is the first thing inside, above the breakdown that explains it.
    ///
    /// Always present, even where nothing can be counted — the same treatment
    /// the on-device model's row gets. Hiding it outright was the first shape
    /// and it was wrong: it made "did this ship at all" unanswerable from the
    /// only place it lives.
    private func contextBudgetMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Context Budget", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // Its own delegate, so opening *this* is what triggers the on-device
        // measurement — the only refresh in the app that costs inference, and
        // therefore the only one that waits to be asked for specifically.
        submenu.delegate = self
        submenu.identifier = Self.budgetMenuIdentifier
        populateBudget(submenu)
        parent.submenu = submenu
        return parent
    }

    private func populateBudget(_ submenu: NSMenu) {
        submenu.removeAllItems()

        switch PrefixBudget.shared.reading {
        case .tokens(let measurement):
            submenu.addItem(disabled(
                "Total — \(Self.tokens(measurement.total)) of "
                    + "\(Self.number(measurement.contextSize)) "
                    + "(\(measurement.percentOfContext)%)"))
            submenu.addItem(.separator())
            for (title, count) in [
                ("System Prompt", measurement.systemPrompt),
                ("Tool Schema", measurement.toolSchema),
                ("Chat Template", measurement.template),
            ] {
                submenu.addItem(disabled("\(title) — \(Self.tokens(count))"))
            }
            submenu.addItem(.separator())
            submenu.addItem(disabled("Counted by the loaded model's own tokeniser."))

        case .onDevice(let device):
            populateOnDeviceBudget(submenu, device)

        case .unavailable(let reason):
            let note = disabled(reason)
            note.toolTip = "Rosy measures her own prefix with the tokeniser of the "
                + "model that is loaded, which only a running local server provides."
            submenu.addItem(note)

        case .none:
            submenu.addItem(disabled(
                PrefixBudget.shared.isMeasuring ? "Measuring…" : "Nothing measured yet."))
        }
    }

    private func populateOnDeviceBudget(_ submenu: NSMenu, _ device: PrefixBudget.OnDevice) {
        if let measured = device.measured {
            // No "of N": Apple publishes no context length, so there is no
            // denominator and a percentage would be invented.
            submenu.addItem(disabled("Total — \(Self.tokens(measured.total))"))
            submenu.addItem(.separator())
            submenu.addItem(disabled("System Prompt — \(Self.tokens(measured.instructions))"))
            submenu.addItem(disabled("Tool Schema — \(Self.tokens(measured.toolSchema))"))
            let framing = disabled("Model framing — \(Self.tokens(measured.framing))")
            framing.toolTip = "Apple's own scaffolding, plus the single character "
                + "Rosy sends in place of a question that has not been typed yet."
            submenu.addItem(framing)
        } else if PrefixBudget.shared.isMeasuring {
            submenu.addItem(disabled("Measuring…"))
            submenu.addItem(.separator())
            submenu.addItem(disabled(
                "System Prompt — \(Self.characters(device.systemPromptCharacters))"))
        } else {
            submenu.addItem(disabled(
                "System Prompt — \(Self.characters(device.systemPromptCharacters))"))
        }

        if let lastInputTokens = device.lastInputTokens {
            submenu.addItem(.separator())
            let last = disabled(
                "Last request — \(Self.number(lastInputTokens)) input tokens")
            last.toolTip = "Apple's own count for the whole of the last answer's "
                + "input: instructions, conversation, any tool results, and the "
                + "question. Not the prefix alone, so it is not a share of the "
                + "line above."
            submenu.addItem(last)
        }

        submenu.addItem(.separator())
        let note: NSMenuItem
        if device.measured != nil {
            note = disabled("Measured by asking the model to read its own prefix.")
            note.toolTip = "Apple ships no tokeniser and publishes no context length. "
                + "Rosy sends a one-character prompt and reads back what the model "
                + "says it was given, three times, so each part is a difference. "
                + "It costs about a second and is kept until the prefix changes."
        } else if device.canMeasure {
            note = disabled("Opening this measures the prefix — it runs the model.")
        } else {
            note = disabled("Apple publishes no tokeniser or context length.")
            note.toolTip = "Measuring the prefix needs the usage figures macOS 27 "
                + "introduced. On this version there is no real token count to give, "
                + "and an estimate would be wrong by a wide margin on text carrying "
                + "emoji, which cost several tokens each."
        }
        submenu.addItem(note)
    }

    private static func characters(_ count: Int) -> String {
        "\(number(count)) character\(count == 1 ? "" : "s")"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private static func tokens(_ count: Int) -> String {
        "\(number(count)) token\(count == 1 ? "" : "s")"
    }

    private static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func skillsMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Skills", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for skill in RosySkill.allCases {
            let enabled = SkillSettings.isEnabled(skill)
            // A skill that is on but cannot work should say so here rather
            // than in an error the user only meets after asking a question.
            let needsKey = skill == .webSearch && enabled && !KagiCredentialStore.hasKey
            let title = needsKey ? "\(skill.title) — needs a key" : skill.title
            let entry = item(title, #selector(toggleSkill(_:)))
            entry.representedObject = skill.rawValue
            entry.state = enabled ? .on : .off
            if needsKey {
                entry.toolTip = "Save a Kagi API token in Settings → Web Search."
            }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let routing = NSMenuItem(title: "Tool Routing", action: nil, keyEquivalent: "")
        let routingMenu = NSMenu()
        routingMenu.autoenablesItems = false
        for mode in SkillSettings.RoutingMode.allCases {
            let entry = item(mode.title, #selector(selectToolRouting(_:)))
            entry.representedObject = mode.rawValue
            entry.state = SkillSettings.routingMode() == mode ? .on : .off
            routingMenu.addItem(entry)
        }
        routing.submenu = routingMenu
        submenu.addItem(routing)
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

        let wasElsewhere = InferenceSource.current() != .local
        let changed = wasElsewhere
            || !ModelStore.shared.isSelected(url)
        CloudModelStore.shared.selectLocal()
        ModelStore.shared.select(url)
        guard changed else { return }

        // Switching models while serving should hand back a working endpoint;
        // switching while stopped should not start the server behind the user's
        // back, unless there was nothing to run before.
        let server = ServerController.shared
        if wasElsewhere {
            server.start()
        } else if server.state.isBusy {
            server.restart()
        } else if server.state == .noModel {
            server.start()
        }
    }

    @objc private func selectCloudModel() {
        let cloud = CloudModelStore.shared
        guard cloud.configuration != nil else {
            CloudModelWindowController.shared.show()
            return
        }
        guard !cloud.isCloudSelected else { return }
        cloud.selectCloud()
        ServerController.shared.stop()
    }

    @objc private func selectAppleModel() {
        let apple = AppleModelStore.shared
        guard !apple.isSelected else { return }
        apple.select()
        // Nothing local left to serve. The endpoint goes down with it, exactly
        // as it does when a cloud profile is picked — other clients are talking
        // to llama-server, and FoundationModels is not an HTTP server Rosy can
        // put in its place.
        ServerController.shared.stop()
    }

    @objc private func toggleServer() {
        ServerController.shared.toggle()
    }

    @objc private func toggleSkill(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let skill = RosySkill(rawValue: rawValue) else { return }
        SkillSettings.setEnabled(!SkillSettings.isEnabled(skill), for: skill)
        // A changed skill is a changed tool block, so the prefix it costs
        // changes with it.
        Task { @MainActor in PrefixBudget.shared.refresh() }

        // A changed tool block means a changed reusable prefix. Refill it now
        // when the local runtime is ready; a starting server will perform the
        // same warm when its health probe succeeds. Cloud APIs need no warm.
        if InferenceSource.current() == .local,
           ServerController.shared.state == .running {
            Task { @MainActor in ChatClient.warmPrefix() }
        }
    }

    @objc private func selectToolRouting(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = SkillSettings.RoutingMode(rawValue: rawValue),
              mode != SkillSettings.routingMode() else { return }
        SkillSettings.setRoutingMode(mode)
        Task { @MainActor in PrefixBudget.shared.refresh() }
        if InferenceSource.current() == .local,
           ServerController.shared.state == .running {
            Task { @MainActor in ChatClient.warmPrefix() }
        }
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

    @objc private func showChat() {
        ChatWindowController.shared.show()
    }

    @objc private func showModelSetup() {
        ModelSetupWindowController.shared.show()
    }

    @objc private func showCloudModel() {
        CloudModelWindowController.shared.show()
    }

    @objc private func showHuggingFaceImport() {
        HuggingFaceImportWindowController.shared.show()
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
