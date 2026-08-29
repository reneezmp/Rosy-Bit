import Combine
import Darwin
import Foundation

/// Owns the bundled `llama-server` child process.
///
/// Gotcha #4: nothing here runs on a timer. Liveness comes from
/// `Process.terminationHandler` (free), readiness comes from watching the
/// server's own stdout as it streams past on its way to the log file, and the
/// `/health` endpoint is only ever touched when the menu is opened *and* we are
/// still waiting for the model to load.
///
/// All state is read and written on the main thread; background callbacks hop
/// through `DispatchQueue.main`. Because those callbacks can land after the run
/// they belong to is over — a restart is exactly this case — each run carries a
/// `generation` token and late callbacks from a previous generation are dropped.
final class ServerController: ObservableObject {

    static let shared = ServerController()

    enum State: Equatable {
        case stopped
        case starting
        case running
        case noModel
        case failed(String)
        case portBusy(String)

        var isBusy: Bool {
            switch self {
            case .starting, .running: return true
            case .stopped, .noModel, .failed, .portBusy: return false
            }
        }

        var menuTitle: String {
            switch self {
            case .stopped:
                return "○ Stopped"
            case .starting:
                return "◌ Starting…"
            case .running:
                return "● Running — \(Config.host):\(Config.port)"
            case .noModel:
                return "⚠ No model — open the models folder"
            case .failed(let reason):
                return "⚠ \(reason)"
            case .portBusy(let occupant):
                return "⚠ Port \(Config.port) held by \(occupant)"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var activeModelName: String?

    private var process: Process?
    private var logHandle: FileHandle?
    private var isStopping = false
    private var healthProbeInFlight = false

    /// Bumped whenever a run begins or ends, so callbacks can tell whether the
    /// run they belong to is still the current one.
    private var generation = 0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }

        guard let executable = Config.serverExecutable else {
            state = .failed("Bundled llama-server missing for \(Config.currentArch)")
            return
        }
        guard let model = ModelStore.shared.selectedModel else {
            state = .noModel
            return
        }

        switch PortGuard.prepare(port: Config.port, pidFile: Config.pidFile) {
        case .clear, .clearedOrphan:
            break
        case .blocked(let occupant):
            state = .portBusy(occupant)
            return
        }

        let alias = model.deletingPathExtension().lastPathComponent
        let arguments = Config.serverArguments(modelPath: model.path, alias: alias)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // The release tarballs ship llama-server next to its dylibs. @rpath
        // normally resolves those already; this is a harmless belt-and-braces
        // for a build whose rpath was set differently.
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = executable.deletingLastPathComponent().path
        process.environment = environment

        let logHandle = Self.openLog(invocation: ([executable.path] + arguments).joined(separator: " "))
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        generation += 1
        let token = generation

        // Tee: every byte goes to the log, and the same bytes are scanned for
        // the line where the server announces it is accepting connections.
        let scanner = ReadyLineScanner()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? logHandle?.write(contentsOf: data)
            if scanner.consume(data) {
                DispatchQueue.main.async { ServerController.shared.markReady(token: token) }
            }
        }

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let signalled = finished.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                ServerController.shared.handleTermination(
                    token: token, status: status, signalled: signalled)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()
            state = .failed("Could not launch llama-server: \(error.localizedDescription)")
            return
        }

        self.process = process
        self.logHandle = logHandle
        self.activeModelName = alias
        self.isStopping = false
        self.state = .starting

        PortGuard.writePidFile(Config.pidFile, pid: process.processIdentifier)
    }

    func stop() {
        guard let process, process.isRunning else {
            cleanUp()
            state = .stopped
            return
        }
        isStopping = true
        process.terminate()

        // If it ignores SIGTERM, insist.
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let current = self.process, current.isRunning,
                  current.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    func restart() {
        terminateSynchronously()
        state = .stopped
        start()
    }

    func toggle() {
        if state.isBusy { stop() } else { start() }
    }

    /// Called from `applicationWillTerminate`, where there is no time left for
    /// an async round trip: the child must be gone before we return.
    func terminateSynchronously(timeout: TimeInterval = 3) {
        isStopping = true
        defer {
            cleanUp()
            try? FileManager.default.removeItem(at: Config.pidFile)
        }
        guard let process, process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Status

    /// Called when the menu bar menu opens. Cheap by design.
    func refreshStatus() {
        guard process == nil else {
            // We own a live child; only the loading→ready transition is worth a
            // request, and only as a backstop if the log line was not matched.
            if state == .starting { probeHealth() }
            return
        }
        // Nothing of ours is running. A pure syscall (no network, no CPU wake)
        // tells us whether something else has taken the port.
        let free = PortGuard.isPortFree(Config.port)
        switch (state, free) {
        case (.portBusy, true):
            state = .stopped
        case (.stopped, false):
            state = .portBusy("another process")
        default:
            break
        }
    }

    private func probeHealth() {
        guard !healthProbeInFlight, let url = Config.healthURL else { return }
        healthProbeInFlight = true
        let token = generation

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ready = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                ServerController.shared.healthProbeInFlight = false
                if ready { ServerController.shared.markReady(token: token) }
            }
        }.resume()
    }

    private func markReady(token: Int) {
        guard token == generation, state == .starting else { return }
        state = .running
    }

    private func handleTermination(token: Int, status: Int32, signalled: Bool) {
        guard token == generation else { return }

        let wasDeliberate = isStopping
        cleanUp()
        try? FileManager.default.removeItem(at: Config.pidFile)

        if wasDeliberate {
            state = .stopped
        } else if signalled {
            state = .failed("llama-server was killed (signal \(status))")
        } else {
            state = .failed("llama-server exited with code \(status)")
        }
    }

    private func cleanUp() {
        // Invalidate anything still in flight from the run being torn down.
        generation += 1

        if let current = process, let pipe = current.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminationHandler = nil
        process = nil
        try? logHandle?.close()
        logHandle = nil
        activeModelName = nil
        isStopping = false
    }

    // MARK: - Logging

    private static func openLog(invocation: String) -> FileHandle? {
        let url = Config.logFile
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        try? handle.truncate(atOffset: 0)

        let header = "# Rosy Bit — \(Date())\n# \(invocation)\n\n"
        try? handle.write(contentsOf: Data(header.utf8))
        return handle
    }
}

/// Watches the server's own output for the point at which it starts accepting
/// connections. Only ever touched from the pipe's reader queue.
private final class ReadyLineScanner {
    /// Wording has drifted between llama.cpp releases, so match several.
    private static let markers = [
        "server is listening",
        "starting the main loop",
        "HTTP server listening",
        "all slots are idle",
    ]

    private var tail = ""
    private var fired = false

    func consume(_ data: Data) -> Bool {
        guard !fired, let text = String(data: data, encoding: .utf8) else { return false }
        tail += text
        if tail.count > 4096 {
            tail = String(tail.suffix(2048))
        }
        guard Self.markers.contains(where: tail.contains) else { return false }
        fired = true
        tail = ""
        return true
    }
}
