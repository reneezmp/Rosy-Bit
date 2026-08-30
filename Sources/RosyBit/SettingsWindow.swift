import AppKit
import Combine
import SwiftUI

/// Every value the settings window edits, in one comparable place so the window
/// can tell whether anything has actually changed.
struct SettingsValues: Equatable {
    var contextSize = 2048
    var threads = 2
    var parallelSlots = 1
    var kvCacheType = ""
    var flashAttention = ""

    var temperature = Config.ModelCard.temperature
    var topK = Config.ModelCard.topK
    var topP = Config.ModelCard.topP
    var repeatPenalty = Config.ModelCard.repeatPenalty
    var presencePenalty = Config.ModelCard.presencePenalty

    var systemPrompt = ""
    var corsOrigins = ""
    var port = 1337

    var insightsEnabled = true
    var upstreamPort = 11337
    var insightsCapacity = 200

    var askBarEnabled = true
    var hotKeyCode = 49
    var hotKeyModifiers = 2048

    /// llama-server takes these as launch arguments, so changing one means
    /// restarting the child and reloading the model. The rest — the system
    /// prompt, the shortcut, how many requests Insights keeps — apply live, and
    /// restarting for those would cost a model load for nothing.
    func needsServerRestart(comparedTo other: SettingsValues) -> Bool {
        contextSize != other.contextSize
            || threads != other.threads
            || parallelSlots != other.parallelSlots
            || kvCacheType != other.kvCacheType
            || flashAttention != other.flashAttention
            || temperature != other.temperature
            || topK != other.topK
            || topP != other.topP
            || repeatPenalty != other.repeatPenalty
            || presencePenalty != other.presencePenalty
            || corsOrigins != other.corsOrigins
            || port != other.port
            || insightsEnabled != other.insightsEnabled
            || upstreamPort != other.upstreamPort
    }
}

/// Reads and writes the same `UserDefaults` keys `Config` reads, so everything
/// here is equally reachable with `defaults write`.
final class SettingsModel: ObservableObject {

    @Published var values = SettingsValues()
    @Published private(set) var savedNotice: String?

    private var saved = SettingsValues()
    private var noticeTask: Task<Void, Never>?

    var isDirty: Bool { values != saved }

    func load() {
        var loaded = SettingsValues()
        loaded.contextSize = Config.contextSize
        loaded.threads = Config.threads
        loaded.parallelSlots = Config.parallelSlots
        loaded.kvCacheType = Config.kvCacheType ?? ""
        loaded.flashAttention = Config.flashAttention ?? ""
        loaded.temperature = Config.temperature
        loaded.topK = Config.topK
        loaded.topP = Config.topP
        loaded.repeatPenalty = Config.repeatPenalty
        loaded.presencePenalty = Config.presencePenalty
        loaded.systemPrompt = Config.systemPrompt ?? ""
        loaded.corsOrigins = Config.corsOrigins ?? ""
        loaded.port = Config.port
        loaded.insightsEnabled = Config.insightsEnabled
        loaded.upstreamPort = Config.upstreamPort
        loaded.insightsCapacity = Config.insightsCapacity
        loaded.askBarEnabled = Config.askBarEnabled
        loaded.hotKeyCode = Config.hotKeyCode
        loaded.hotKeyModifiers = Config.hotKeyModifiers

        values = loaded
        saved = loaded
        savedNotice = nil
    }

    /// Why the settings cannot be applied, or nil when they can.
    var validationError: String? {
        let range = 1024...65535
        guard range.contains(values.port) else {
            return "Port must be between \(range.lowerBound) and \(range.upperBound)."
        }
        guard !values.insightsEnabled || range.contains(values.upstreamPort) else {
            return "llama-server port must be between \(range.lowerBound) and \(range.upperBound)."
        }
        guard !values.insightsEnabled || values.port != values.upstreamPort else {
            return "The two ports must differ — the proxy cannot forward to itself."
        }
        guard !values.askBarEnabled || values.hotKeyModifiers != 0 else {
            return "A shortcut needs at least one modifier key."
        }
        return nil
    }

    func apply() {
        guard validationError == nil, isDirty else { return }

        let defaults = UserDefaults.standard
        let restartNeeded = values.needsServerRestart(comparedTo: saved)
        let shortcutChanged = values.hotKeyCode != saved.hotKeyCode
            || values.hotKeyModifiers != saved.hotKeyModifiers
            || values.askBarEnabled != saved.askBarEnabled

        defaults.set(values.contextSize, forKey: "contextSize")
        defaults.set(values.threads, forKey: "threads")
        defaults.set(values.parallelSlots, forKey: "parallelSlots")
        defaults.set(values.temperature, forKey: "temperature")
        defaults.set(values.topK, forKey: "topK")
        defaults.set(values.topP, forKey: "topP")
        defaults.set(values.repeatPenalty, forKey: "repeatPenalty")
        defaults.set(values.presencePenalty, forKey: "presencePenalty")
        defaults.set(values.port, forKey: "port")
        defaults.set(values.insightsEnabled, forKey: "insightsEnabled")
        defaults.set(values.upstreamPort, forKey: "upstreamPort")
        defaults.set(values.insightsCapacity, forKey: "insightsCapacity")
        defaults.set(values.askBarEnabled, forKey: "askBarEnabled")
        defaults.set(values.hotKeyCode, forKey: "hotKeyCode")
        defaults.set(values.hotKeyModifiers, forKey: "hotKeyModifiers")

        setOrRemove(values.kvCacheType, forKey: "kvCacheType")
        setOrRemove(values.flashAttention, forKey: "flashAttention")
        setOrRemove(values.corsOrigins, forKey: "corsOrigins")
        setOrRemove(values.systemPrompt, forKey: "systemPrompt", trimming: false)

        saved = values

        if shortcutChanged {
            AskBarWindowController.shared.registerHotKey()
        }
        if restartNeeded {
            ServerController.shared.restart()
            show(notice: "Saved — restarting the server")
        } else {
            show(notice: "Saved")
        }
    }

    func useModelCardValues() {
        values.temperature = Config.ModelCard.temperature
        values.topK = Config.ModelCard.topK
        values.topP = Config.ModelCard.topP
        values.repeatPenalty = Config.ModelCard.repeatPenalty
        values.presencePenalty = Config.ModelCard.presencePenalty
    }

    func restoreDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            "contextSize", "threads", "parallelSlots", "kvCacheType", "flashAttention",
            "temperature", "topK", "topP", "repeatPenalty", "presencePenalty",
            "systemPrompt", "corsOrigins", "port", "insightsEnabled", "upstreamPort",
            "insightsCapacity", "askBarEnabled", "hotKeyCode", "hotKeyModifiers",
        ] {
            defaults.removeObject(forKey: key)
        }
        load()
        show(notice: "Restored")
    }

    private func show(notice: String) {
        savedNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            // Captured again for the inner closure rather than reaching out to
            // the outer weak var, which Swift 6 rejects outright.
            await MainActor.run { [weak self] in self?.savedNotice = nil }
        }
    }

    private func setOrRemove(_ value: String, forKey key: String, trimming: Bool = true) {
        // A system prompt keeps its own line breaks; a port or cache type does not.
        let stored = trimming ? value.trimmingCharacters(in: .whitespaces) : value
        if stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(stored, forKey: key)
        }
    }

    /// Bonsai is 28 layers with 8 KV heads at head_dim 128 — 112 KiB per token
    /// at f16. Quantising the cache roughly halves or quarters it.
    var kvCacheEstimate: String {
        var bytesPerToken = 112.0 * 1024
        switch values.kvCacheType {
        case "q8_0": bytesPerToken /= 2
        case "q4_0": bytesPerToken /= 4
        default: break
        }
        let total = Int64(bytesPerToken * Double(values.contextSize))
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
    }
}

final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private let model = SettingsModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Rosy Bit Settings"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        model.load()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    private static let contextSizes = [2048, 4096, 8192, 16384, 32768]

    /// A short list rather than a key recorder: enough to get off a shortcut
    /// something else has claimed, without a whole capture UI.
    private static let keys: [(name: String, code: Int)] = [
        ("Space", 49), ("Return", 36), ("/", 44),
        ("B", 11), ("J", 38), ("K", 40), ("R", 15),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                modelSection
                samplingSection
                systemPromptSection
                askBarSection
                performanceSection
                endpointSection
                insightsSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 540)
    }

    private var modelSection: some View {
        Section("Model") {
            Picker("Context size", selection: $model.values.contextSize) {
                ForEach(Self.contextSizes, id: \.self) { Text("\($0) tokens").tag($0) }
            }
            LabeledContent("KV cache") {
                Text(model.kvCacheEstimate).foregroundStyle(.secondary)
            }

            Picker("Cache precision", selection: $model.values.kvCacheType) {
                Text("f16 (default)").tag("")
                Text("q8_0 — half the memory").tag("q8_0")
                Text("q4_0 — a quarter").tag("q4_0")
            }
            Text("Generation reads the whole cache for every token, so a smaller one may "
                 + "also be faster at long contexts. q8_0 is close to lossless; q4_0 is "
                 + "not, and this model has little quality to spare.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Flash attention", selection: $model.values.flashAttention) {
                Text("llama-server decides").tag("")
                Text("on").tag("on")
                Text("off").tag("off")
                Text("auto").tag("auto")
            }
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            Text("These start at the values Bonsai's model card recommends, not "
                 + "llama.cpp's hotter defaults. Change them freely — the button puts "
                 + "them back.")
                .font(.caption)
                .foregroundStyle(.secondary)

            slider("Temperature", $model.values.temperature, range: 0...2, step: 0.05,
                   hint: "Card suggests 0.5 – 0.7")
            Stepper("Top-k: \(model.values.topK)", value: $model.values.topK, in: 1...200)
            Text("Card suggests 20 – 40")
                .font(.caption)
                .foregroundStyle(.secondary)
            slider("Top-p", $model.values.topP, range: 0...1, step: 0.01,
                   hint: "Card suggests 0.85 – 0.95")
            slider("Repetition penalty", $model.values.repeatPenalty, range: 1...1.5, step: 0.05,
                   hint: "1.0 is off. Raise towards 1.1 if long answers start repeating.")
            slider("Presence penalty", $model.values.presencePenalty, range: -2...2, step: 0.1,
                   hint: nil)

            Button("Reset to the model card") { model.useModelCardValues() }
        }
    }

    private var systemPromptSection: some View {
        Section("System Prompt") {
            TextEditor(text: $model.values.systemPrompt)
                .font(.callout)
                .frame(minHeight: 80)

            Text("Used only by Rosy Bit's own ask bar. It is never added to requests from "
                 + "other applications — those send their own messages and pass through "
                 + "untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var askBarSection: some View {
        Section("Ask Bar") {
            Toggle("Enable the shortcut", isOn: $model.values.askBarEnabled)

            if model.values.askBarEnabled {
                Picker("Key", selection: $model.values.hotKeyCode) {
                    ForEach(Self.keys, id: \.code) { Text($0.name).tag($0.code) }
                }
                HStack(spacing: 12) {
                    modifierToggle("⌘", 256)
                    modifierToggle("⌥", 2048)
                    modifierToggle("⌃", 4096)
                    modifierToggle("⇧", 512)
                    Spacer()
                    Text(shortcutDescription)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !AskBarWindowController.shared.hotKeyRegistered {
                    Text("This shortcut could not be registered — something else on the "
                         + "system already owns it. Pick another.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            Stepper("Threads: \(model.values.threads)", value: $model.values.threads, in: 1...16)
            Stepper("Parallel slots: \(model.values.parallelSlots)",
                    value: $model.values.parallelSlots, in: 1...8)
            Text("One slot measured about 24% faster at a 1300-token prompt than four.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var endpointSection: some View {
        Section("Endpoint") {
            TextField("Port", value: $model.values.port, format: .number.grouping(.never))
            TextField("Allowed browser origins", text: $model.values.corsOrigins,
                      prompt: Text("empty — allow all"))
            Text("Loopback keeps the network out but not browsers. Native clients send no "
                 + "Origin and are unaffected either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var insightsSection: some View {
        Section("Insights") {
            Toggle("Record requests", isOn: $model.values.insightsEnabled)
            if model.values.insightsEnabled {
                TextField("llama-server port", value: $model.values.upstreamPort,
                          format: .number.grouping(.never))
                Stepper("Keep \(model.values.insightsCapacity) requests",
                        value: $model.values.insightsCapacity, in: 10...2000, step: 10)
                Text("Held in memory only and never written to disk, so quitting Rosy Bit "
                     + "erases them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Button("Restore Defaults") { model.restoreDefaults() }

            Spacer()

            if let problem = model.validationError, model.isDirty {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            } else if let notice = model.savedNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button("Apply") { model.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || model.validationError != nil)
        }
        .padding(12)
    }

    // MARK: - Pieces

    private func modifierToggle(_ symbol: String, _ mask: Int) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { model.values.hotKeyModifiers & mask != 0 },
            set: { isOn in
                if isOn {
                    model.values.hotKeyModifiers |= mask
                } else {
                    model.values.hotKeyModifiers &= ~mask
                }
            }))
        .toggleStyle(.button)
    }

    private var shortcutDescription: String {
        var text = ""
        if model.values.hotKeyModifiers & 4096 != 0 { text += "⌃" }
        if model.values.hotKeyModifiers & 2048 != 0 { text += "⌥" }
        if model.values.hotKeyModifiers & 512 != 0 { text += "⇧" }
        if model.values.hotKeyModifiers & 256 != 0 { text += "⌘" }
        let key = Self.keys.first { $0.code == model.values.hotKeyCode }?.name ?? "?"
        return text + key
    }

    private func slider(
        _ label: String, _ value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, hint: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Slider(value: value, in: range, step: step)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.callout.monospaced())
                    .frame(width: 44, alignment: .trailing)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
