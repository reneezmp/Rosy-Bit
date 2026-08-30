import Foundation

/// Static configuration for the bundled `llama-server`.
///
/// Everything here has a sensible default and no UI. The knobs that might
/// plausibly need changing on a fanless two-core machine can be overridden
/// without a rebuild, e.g. if generation makes the cursor stutter:
///
///     defaults write com.rosybit.app threads -int 1
///     killall RosyBit
enum Config {
    static let bundleIdentifier = "com.rosybit.app"

    /// Loopback only. Rosy travels; this must never be reachable off-device.
    static let host = "127.0.0.1"

    /// 1337 matches Osaurus on the M4, so a client configured for one machine
    /// works unmodified on the other.
    static var port: Int { intDefault("port", fallback: 1337, clampedTo: 1024...65535) }

    static var contextSize: Int { intDefault("contextSize", fallback: 2048, clampedTo: 256...32768) }

    /// Both cores of the Core m3. Drop to 1 if the UI stutters during generation.
    static var threads: Int { intDefault("threads", fallback: 2, clampedTo: 1...16) }

    /// The URL users paste into an app's "custom base URL" field.
    static var endpointURL: String { "http://\(host):\(port)/v1" }

    static var healthURL: URL? { URL(string: "http://\(host):\(port)/health") }

    static var chatCompletionsURL: URL? {
        URL(string: "http://\(host):\(port)/v1/chat/completions")
    }

    /// Prepended to conversations started from inside Rosy Bit. Does not affect
    /// other clients, which send their own.
    ///
    ///     defaults write com.rosybit.app systemPrompt "Answer in one sentence."
    static var systemPrompt: String? { nonEmptyString("systemPrompt") }

    /// The ⌥Space ask bar. Set false to leave the shortcut unregistered.
    static var askBarEnabled: Bool {
        (UserDefaults.standard.object(forKey: "askBarEnabled") as? Bool) ?? true
    }

    /// Where the first-run downloader looks. The Hugging Face API is asked which
    /// files exist rather than guessing at the exact casing of the filename.
    static var modelRepository: String {
        nonEmptyString("modelRepository") ?? "prism-ml/Bonsai-1.7B-gguf"
    }

    /// Which quantisation to prefer among the `.gguf` files in that repository.
    static var modelQuant: String { nonEmptyString("modelQuant") ?? "Q1_0" }

    /// A Bonsai size the menu can offer to fetch.
    struct KnownModel: Identifiable {
        let name: String
        let repository: String
        let billions: Double
        /// Matched against the files on disk to tell whether this one is here.
        let filenameHint: String

        var id: String { repository }

        /// Q1_0 packs about 1.125 bits per weight, which is close enough to
        /// tell someone what they are about to download.
        var approximateBytes: Int64 { Int64(billions * 1e9 * 1.125 / 8) }

        var approximateSize: String {
            ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
        }
    }

    /// Size and prompt length multiply, so the right model depends on the job
    /// rather than the machine: a 4B answers a short prompt on Rosy in seconds,
    /// and the same 4B against a whole transcript multiplies a wait that is
    /// already minutes.
    static let knownModels: [KnownModel] = [
        KnownModel(name: "Bonsai 1.7B", repository: "prism-ml/Bonsai-1.7B-gguf",
                   billions: 1.7, filenameHint: "1.7B"),
        KnownModel(name: "Bonsai 4B", repository: "prism-ml/Bonsai-4B-gguf",
                   billions: 4, filenameHint: "4B"),
        KnownModel(name: "Bonsai 8B", repository: "prism-ml/Bonsai-8B-gguf",
                   billions: 8, filenameHint: "8B"),
    ]

    /// Models live outside the bundle so they can be swapped without rebuilding.
    static var modelDirectory: URL {
        libraryDirectory
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RosyBit", isDirectory: true)
    }

    static var logFile: URL {
        libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RosyBit", isDirectory: true)
            .appendingPathComponent("llama-server.log")
    }

    /// Hidden inside the model directory so it does not clutter the folder the
    /// user actually browses to drop `.gguf` files into.
    static var pidFile: URL {
        modelDirectory.appendingPathComponent(".llama-server.pid")
    }

    /// The bundled `llama-server` for the architecture we are running on.
    /// `make app` stages both slices under `Contents/Resources/llama/`.
    static var serverExecutable: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("llama", isDirectory: true)
            .appendingPathComponent(currentArch, isDirectory: true)
            .appendingPathComponent("llama-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Where llama-server actually listens when Insights is on. Rosy Bit takes
    /// the public port and forwards, which is the only way it can see the
    /// request and response bodies — it supervises someone else's server rather
    /// than being one. Nothing outside the app should need this port.
    static var upstreamPort: Int { intDefault("upstreamPort", fallback: 11337, clampedTo: 1024...65535) }

    /// The escape hatch. Set false and llama-server binds the public port
    /// directly, with no proxy in the request path and no Insights:
    ///
    ///     defaults write com.rosybit.app insightsEnabled -bool false
    ///
    /// Worth knowing about, because with Insights on, an app crash takes the
    /// endpoint down with it. Without it, llama-server keeps serving.
    static var insightsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "insightsEnabled") as? Bool) ?? true
    }

    /// The port llama-server is told to bind — behind the proxy, or in front of
    /// it when Insights is off.
    static var serverBindPort: Int { insightsEnabled ? upstreamPort : port }

    /// How many requests Insights keeps. In memory only, never written to disk:
    /// on this machine the buffer holds meeting transcripts, so quitting the app
    /// has to be enough to erase them.
    static var insightsCapacity: Int { intDefault("insightsCapacity", fallback: 200, clampedTo: 10...2000) }

    /// How many requests llama-server can hold in flight at once.
    ///
    /// One rather than llama-server's default of four, for two measured
    /// reasons: two cores cannot usefully generate four replies at once, and
    /// generation ran about 24% faster on one slot than four at a 1300-token
    /// prompt (3.70 vs 2.98 tok/s).
    ///
    /// Whether slots multiply KV memory is *not* established. Bonsai's cache is
    /// 112 KiB per token at f16, confirmed by measurement at one slot, but the
    /// four-slot case was never measured and llama-server reports
    /// `kv_unified = 'true'` there, which may mean the slots share one cache.
    /// Don't assume the multiplier without checking — see docs/RUNBOOK.md.
    ///
    ///     defaults write com.rosybit.app parallelSlots -int 2
    static var parallelSlots: Int { intDefault("parallelSlots", fallback: 1, clampedTo: 1...8) }

    /// Quantises the KV cache, e.g. `q8_0` to roughly halve the memory above
    /// for very little quality cost. Unset leaves llama-server on f16.
    ///
    /// Some builds refuse a quantised V cache without flash attention. If the
    /// server exits at startup after setting this, check the log — that is the
    /// likely reason.
    ///
    ///     defaults write com.rosybit.app kvCacheType q8_0
    static var kvCacheType: String? { nonEmptyString("kvCacheType") }

    /// Sampling defaults come from Bonsai's model card rather than llama.cpp,
    /// whose own are hotter — temperature 0.8 against the card's 0.5, top-k 40
    /// against 20 — in the direction that makes a small model wander and
    /// repeat. The card is the better authority for the model actually being
    /// served, so it is what ships; each value stays individually overridable.
    ///
    /// Card: temperature 0.5 (range 0.5–0.7), top-k 20 (20–40),
    /// top-p 0.9 (0.85–0.95), repetition penalty 1.0, presence penalty 0.0.
    enum ModelCard {
        static let temperature = 0.5
        static let topK = 20
        static let topP = 0.9
        static let repeatPenalty = 1.0
        static let presencePenalty = 0.0
    }

    /// Sampling temperature. Note that an OpenAI-compatible client sending its
    /// own `temperature` overrides this per request, which most of them do.
    ///
    ///     defaults write com.rosybit.app temperature -float 0.7
    static var temperature: Double {
        optionalDouble("temperature", clampedTo: 0...2) ?? ModelCard.temperature
    }

    /// Penalises tokens the model has already used, which is the usual lever
    /// against a long generation collapsing into repeating itself. Recent
    /// llama.cpp defaults this to 1.0, meaning off. 1.1 is the conventional
    /// mild setting.
    ///
    ///     defaults write com.rosybit.app repeatPenalty -float 1.1
    static var repeatPenalty: Double {
        optionalDouble("repeatPenalty", clampedTo: 1...2) ?? ModelCard.repeatPenalty
    }

    /// Sampling, per Bonsai's model card. llama.cpp's own defaults differ —
    /// temperature 0.8 against the card's 0.5, top-k 40 against 20 — so leaving
    /// these unset means running the model hotter than its authors suggest,
    /// which is exactly the condition a small model loops in.
    ///
    /// The card gives: temperature 0.5 (0.5–0.7), top-k 20 (20–40),
    /// top-p 0.9 (0.85–0.95), repetition penalty 1.0, presence penalty 0.0.
    static var topK: Int { optionalInt("topK", clampedTo: 1...200) ?? ModelCard.topK }

    static var topP: Double { optionalDouble("topP", clampedTo: 0...1) ?? ModelCard.topP }

    static var presencePenalty: Double {
        optionalDouble("presencePenalty", clampedTo: -2...2) ?? ModelCard.presencePenalty
    }

    /// The ask bar's shortcut. Stored as a virtual key code and a Carbon
    /// modifier mask, both settable in Settings — ⌥Space is a popular choice
    /// among launchers, so it needs to be changeable.
    static var hotKeyCode: Int { intDefault("hotKeyCode", fallback: 49, clampedTo: 0...255) }

    static var hotKeyModifiers: Int {
        intDefault("hotKeyModifiers", fallback: 2048, clampedTo: 0...8192)  // optionKey
    }

    /// `on`, `off` or `auto`. Quantising the V cache needs flash attention on
    /// some builds; if the server stops starting after setting `kvCacheType`,
    /// this is the first thing to try. Unset leaves llama-server's own choice.
    static var flashAttention: String? { nonEmptyString("flashAttention") }

    /// Restricts which browser origins may call the endpoint.
    ///
    /// Binding to loopback keeps the network out, but it does not keep browsers
    /// out: llama-server reflects any `Origin` back by default, so a page you
    /// happen to be visiting can use this endpoint from JavaScript. It cannot
    /// reach anything but the model — there are no tools and no file access —
    /// so the exposure is CPU time on a fanless machine rather than data. Still
    /// worth closing if you know which clients you need.
    ///
    /// Native clients (curl, scripts, Obsidian's `requestUrl`) send no `Origin`
    /// and are unaffected. Electron apps calling `fetch()` do send one.
    ///
    ///     defaults write com.rosybit.app corsOrigins "app://obsidian.md"
    ///
    /// Unset means llama-server's own default, which is to allow all.
    static var corsOrigins: String? { nonEmptyString("corsOrigins") }

    /// Arguments for the server. Deliberately no `-ngl`: every Bonsai example
    /// assumes CUDA or Apple Silicon Metal, and Rosy has neither.
    static func serverArguments(modelPath: String, alias: String) -> [String] {
        var arguments = [
            "--host", host,
            "--port", String(serverBindPort),
            "-m", modelPath,
            "-c", String(contextSize),
            "-t", String(threads),
            "-np", String(parallelSlots),
            "--jinja",
            "--alias", alias,
        ]
        if let kvCacheType {
            arguments += ["--cache-type-k", kvCacheType, "--cache-type-v", kvCacheType]
        }
        arguments += [
            "--temp", String(temperature),
            "--top-k", String(topK),
            "--top-p", String(topP),
            "--repeat-penalty", String(repeatPenalty),
            "--presence-penalty", String(presencePenalty),
        ]
        if let flashAttention {
            arguments += ["--flash-attn", flashAttention]
        }
        if let corsOrigins {
            arguments += ["--cors-origins", corsOrigins]
        }
        return arguments
    }

    // MARK: - Helpers

    private static var libraryDirectory: URL {
        if let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
    }

    private static func nonEmptyString(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func optionalInt(_ key: String, clampedTo range: ClosedRange<Int>) -> Int? {
        guard let value = UserDefaults.standard.object(forKey: key) as? Int else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func optionalDouble(_ key: String, clampedTo range: ClosedRange<Double>) -> Double? {
        guard let value = UserDefaults.standard.object(forKey: key) as? Double else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func intDefault(_ key: String, fallback: Int, clampedTo range: ClosedRange<Int>) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        guard stored != 0 else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}
