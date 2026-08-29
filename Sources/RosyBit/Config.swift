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
    static var corsOrigins: String? {
        guard let value = UserDefaults.standard.string(forKey: "corsOrigins"),
              !value.isEmpty else { return nil }
        return value
    }

    /// Arguments for the server. Deliberately no `-ngl`: every Bonsai example
    /// assumes CUDA or Apple Silicon Metal, and Rosy has neither.
    static func serverArguments(modelPath: String, alias: String) -> [String] {
        var arguments = [
            "--host", host,
            "--port", String(port),
            "-m", modelPath,
            "-c", String(contextSize),
            "-t", String(threads),
            "--jinja",
            "--alias", alias,
        ]
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

    private static func intDefault(_ key: String, fallback: Int, clampedTo range: ClosedRange<Int>) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        guard stored != 0 else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}
