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
        corsOrigins = Config.corsOrigins ?? ""
        port = Config.port
        insightsEnabled = Config.insightsEnabled
        upstreamPort = Config.upstreamPort
        insightsCapacity = Config.insightsCapacity
    }

    func save() {
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
    }

    func restoreDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            "contextSize", "threads", "parallelSlots", "kvCacheType", "temperature",
            "corsOrigins", "port", "insightsEnabled", "upstreamPort", "insightsCapacity",
        ] {
            defaults.removeObject(forKey: key)
        }
        load()
    }

    private func setOrRemove(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
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

            Toggle("Set a default temperature", isOn: $model.overrideTemperature)
            if model.overrideTemperature {
                HStack {
                    Slider(value: $model.temperature, in: 0...2, step: 0.05)
                    Text(String(format: "%.2f", model.temperature))
                        .font(.callout.monospaced())
                        .frame(width: 44, alignment: .trailing)
                }
                Text("A client that sends its own temperature overrides this, and most do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        HStack {
            Button("Restore Defaults") { model.restoreDefaults() }
            Spacer()
            Button("Apply & Restart Server") {
                model.save()
                ServerController.shared.restart()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
