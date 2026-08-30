import AppKit
import Combine
import SwiftUI

/// Reads and writes the same `UserDefaults` keys `Config` reads, so everything
/// here is equally reachable with `defaults write` — this window is a
/// convenience over that, not a separate source of truth.
///
/// Nothing is applied live: llama-server takes these as launch arguments, so a
/// change means restarting the child.
final class SettingsModel: ObservableObject {

    @Published var contextSize = 2048
    @Published var threads = 2
    @Published var parallelSlots = 1
    @Published var kvCacheType = ""
    @Published var overrideTemperature = false
    @Published var temperature = 0.8
    @Published var overrideRepeatPenalty = false
    @Published var repeatPenalty = 1.1
    @Published var overrideTopK = false
    @Published var topK = 20
    @Published var overrideTopP = false
    @Published var topP = 0.9
    @Published var overridePresencePenalty = false
    @Published var presencePenalty = 0.0
    @Published var flashAttention = ""
    @Published var systemPrompt = ""
    @Published var corsOrigins = ""
    @Published var port = 1337
    @Published var insightsEnabled = true
    @Published var upstreamPort = 11337
    @Published var insightsCapacity = 200

    func load() {
        contextSize = Config.contextSize
        threads = Config.threads
        parallelSlots = Config.parallelSlots
        kvCacheType = Config.kvCacheType ?? ""
        overrideTemperature = Config.temperature != nil
        temperature = Config.temperature ?? 0.8
        overrideRepeatPenalty = Config.repeatPenalty != nil
        repeatPenalty = Config.repeatPenalty ?? 1.1
        overrideTopK = Config.topK != nil
        topK = Config.topK ?? 20
        overrideTopP = Config.topP != nil
        topP = Config.topP ?? 0.9
        overridePresencePenalty = Config.presencePenalty != nil
        presencePenalty = Config.presencePenalty ?? 0
        flashAttention = Config.flashAttention ?? ""
        systemPrompt = Config.systemPrompt ?? ""
        corsOrigins = Config.corsOrigins ?? ""
        port = Config.port
        insightsEnabled = Config.insightsEnabled
        upstreamPort = Config.upstreamPort
        insightsCapacity = Config.insightsCapacity
    }

    /// Why the settings cannot be applied, or nil when they can.
    ///
    /// Config clamps silently on read, so an out-of-range value here would be
    /// saved, ignored, and then disagree with what the window shows — and two
    /// equal ports would have the proxy forwarding to itself.
    var validationError: String? {
        let range = 1024...65535
        guard range.contains(port) else {
            return "Port must be between \(range.lowerBound) and \(range.upperBound)."
        }
        guard !insightsEnabled || range.contains(upstreamPort) else {
            return "llama-server port must be between \(range.lowerBound) and \(range.upperBound)."
        }
        guard !insightsEnabled || port != upstreamPort else {
            return "The two ports must differ — the proxy cannot forward to itself."
        }
        return nil
    }

    func save() {
        guard validationError == nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(contextSize, forKey: "contextSize")
        defaults.set(threads, forKey: "threads")
        defaults.set(parallelSlots, forKey: "parallelSlots")
        defaults.set(port, forKey: "port")
        defaults.set(insightsEnabled, forKey: "insightsEnabled")
        defaults.set(upstreamPort, forKey: "upstreamPort")
        defaults.set(insightsCapacity, forKey: "insightsCapacity")

        // An empty string means "leave llama-server on its own default", which
        // is not the same as passing an empty flag — remove the key instead.
        setOrRemove(kvCacheType, forKey: "kvCacheType")
        setOrRemove(corsOrigins, forKey: "corsOrigins")

        if overrideTemperature {
            defaults.set(temperature, forKey: "temperature")
        } else {
            defaults.removeObject(forKey: "temperature")
        }
        setOrRemove(flashAttention, forKey: "flashAttention")
        setOrRemove(systemPrompt, forKey: "systemPrompt", trimming: false)

        set(repeatPenalty, forKey: "repeatPenalty", when: overrideRepeatPenalty)
        set(topP, forKey: "topP", when: overrideTopP)
        set(presencePenalty, forKey: "presencePenalty", when: overridePresencePenalty)

        if overrideTopK {
            defaults.set(topK, forKey: "topK")
        } else {
            defaults.removeObject(forKey: "topK")
        }
    }

    /// The values Bonsai's model card recommends. llama.cpp's own defaults are
    /// hotter — temperature 0.8, top-k 40 — which is the wrong direction for a
    /// small model that already tends to loop on long answers.
    func applyModelCardDefaults() {
        overrideTemperature = true
        temperature = 0.5
        overrideTopK = true
        topK = 20
        overrideTopP = true
        topP = 0.9
        overrideRepeatPenalty = true
        repeatPenalty = 1.1
        overridePresencePenalty = false
        presencePenalty = 0
    }

    private func set(_ value: Double, forKey key: String, when enabled: Bool) {
        if enabled {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func restoreDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            "contextSize", "threads", "parallelSlots", "kvCacheType", "temperature",
            "repeatPenalty", "topK", "topP", "presencePenalty", "flashAttention",
            "systemPrompt", "corsOrigins", "port", "insightsEnabled", "upstreamPort",
            "insightsCapacity",
        ] {
            defaults.removeObject(forKey: key)
        }
        load()
    }

    private func setOrRemove(_ value: String, forKey key: String, trimming: Bool = true) {
        // A system prompt keeps its own line breaks and indentation; a port or
        // a cache type does not.
        let stored = trimming ? value.trimmingCharacters(in: .whitespaces) : value
        if stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(stored, forKey: key)
        }
    }

    /// Bonsai is 28 layers with 8 KV heads at head_dim 128, which is 112 KiB
    /// per token at f16. Quantising the cache roughly halves or quarters it.
    var kvCacheEstimate: String {
        var bytesPerToken = 112.0 * 1024
        switch kvCacheType {
        case "q8_0": bytesPerToken /= 2
        case "q4_0": bytesPerToken /= 4
        default: break
        }
        let total = Int64(bytesPerToken * Double(contextSize))
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
    }
}

final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private let model = SettingsModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
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
        // Pick up anything changed with `defaults write` since last time.
        model.load()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    private static let contextSizes = [2048, 4096, 8192, 16384, 32768]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                modelSection
                samplingSection
                systemPromptSection
                performanceSection
                endpointSection
                insightsSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private var modelSection: some View {
        Section("Model") {
            Picker("Context size", selection: $model.contextSize) {
                ForEach(Self.contextSizes, id: \.self) { size in
                    Text("\(size) tokens").tag(size)
                }
            }
            LabeledContent("KV cache") {
                Text(model.kvCacheEstimate).foregroundStyle(.secondary)
            }

            Picker("Cache precision", selection: $model.kvCacheType) {
                Text("f16 (default)").tag("")
                Text("q8_0 — half the memory").tag("q8_0")
                Text("q4_0 — a quarter").tag("q4_0")
            }
            Text("Generation reads the whole cache for every token produced, so a smaller "
                 + "one may also be faster at long contexts. q8_0 is close to lossless; "
                 + "q4_0 is not, and this model has little quality to spare.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Flash attention", selection: $model.flashAttention) {
                Text("llama-server decides").tag("")
                Text("on").tag("on")
                Text("off").tag("off")
                Text("auto").tag("auto")
            }
            Text("Some builds need this on before they will accept a quantised cache.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            Text("Bonsai's model card asks for temperature 0.5 and top-k 20. llama.cpp "
                 + "defaults to 0.8 and 40 — hotter than the model wants, which is the "
                 + "direction that makes a small model wander and repeat.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Use the values from Bonsai's model card") {
                model.applyModelCardDefaults()
            }

            Toggle("Temperature", isOn: $model.overrideTemperature)
            if model.overrideTemperature {
                slider($model.temperature, range: 0...2, step: 0.05)
                Text("A client that sends its own temperature overrides this, and most do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Top-k", isOn: $model.overrideTopK)
            if model.overrideTopK {
                Stepper("\(model.topK)", value: $model.topK, in: 1...200)
            }

            Toggle("Top-p", isOn: $model.overrideTopP)
            if model.overrideTopP {
                slider($model.topP, range: 0...1, step: 0.01)
            }

            Toggle("Repetition penalty", isOn: $model.overrideRepeatPenalty)
            if model.overrideRepeatPenalty {
                slider($model.repeatPenalty, range: 1...1.5, step: 0.05)
            }

            Toggle("Presence penalty", isOn: $model.overridePresencePenalty)
            if model.overridePresencePenalty {
                slider($model.presencePenalty, range: -2...2, step: 0.1)
            }
        }
    }

    private var systemPromptSection: some View {
        Section("System Prompt") {
            TextEditor(text: $model.systemPrompt)
                .font(.callout)
                .frame(minHeight: 90)

            Text("Prepended to conversations started from the ask bar. Other clients send "
                 + "their own and are unaffected. Leave empty for none.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(
        _ value: Binding<Double>, range: ClosedRange<Double>, step: Double
    ) -> some View {
        HStack {
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.callout.monospaced())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            Stepper("Threads: \(model.threads)", value: $model.threads, in: 1...16)
            Text("Rosy has two cores. Drop to 1 if the interface stutters while generating.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper("Parallel slots: \(model.parallelSlots)", value: $model.parallelSlots, in: 1...8)
            Text("Each slot holds its own context. One measured about 24% faster at a "
                 + "1300-token prompt than four.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var endpointSection: some View {
        Section("Endpoint") {
            TextField("Port", value: $model.port, format: .number.grouping(.never))
            Text("1337 matches Osaurus, so one client config works on either machine.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Allowed browser origins", text: $model.corsOrigins,
                      prompt: Text("empty — allow all"))
            Text("Loopback keeps the network out but not browsers. Native clients send no "
                 + "Origin and are unaffected either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var insightsSection: some View {
        Section("Insights") {
            Toggle("Record requests", isOn: $model.insightsEnabled)
            Text("Puts Rosy Bit in the request path so it can see prompts and responses. "
                 + "Turn off and llama-server takes the port directly.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.insightsEnabled {
                TextField("llama-server port", value: $model.upstreamPort,
                          format: .number.grouping(.never))
                Stepper("Keep \(model.insightsCapacity) requests",
                        value: $model.insightsCapacity, in: 10...2000, step: 10)
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
            if let problem = model.validationError {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
            Button("Apply & Restart Server") {
                model.save()
                ServerController.shared.restart()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.validationError != nil)
        }
        .padding(12)
    }
}
