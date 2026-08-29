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

    /// Requests llama-server currently has in flight, counted from its own
    /// output. Drives the menu bar indicator.
    @Published private(set) var activeRequests = 0

    private var process: Process?
    private var logHandle: FileHandle?
    private let proxy = ProxyServer()
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

        // Clear the public port first — this also kills a pidfile-tracked
        // orphan wherever it is listening, which matters when insightsEnabled
        // has been toggled and the orphan is on the other port.
        switch PortGuard.prepare(port: Config.port, pidFile: Config.pidFile) {
        case .clear, .clearedOrphan:
            break
        case .blocked(let occupant):
            state = .portBusy(occupant)
            return
        }

        if Config.serverBindPort != Config.port {
            switch PortGuard.prepare(port: Config.serverBindPort, pidFile: Config.pidFile) {
            case .clear, .clearedOrphan:
                break
            case .blocked(let occupant):
                state = .portBusy("\(occupant) on \(Config.serverBindPort)")
                return
            }
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

        // Tee: every byte goes to the log, and the same bytes tell us when the
        // server starts listening and when it is working on a request.
        let scanner = ServerLogScanner()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: the child is gone. The descriptor stays readable forever
                // once it hits EOF, so leaving the handler installed spins the
                // reader queue until cleanUp() gets its turn on the main thread.
                handle.readabilityHandler = nil
                return
            }
            try? logHandle?.write(contentsOf: data)

            let events = scanner.consume(data)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                ServerController.shared.apply(events: events, token: token)
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
            state = .failed("Could not launch llama-server: \(error.localizedDescription)")
            return
        }

        self.process = process
        self.logHandle = logHandle
        self.activeModelName = alias
        self.isStopping = false
        self.state = .starting

        PortGuard.writePidFile(Config.pidFile, pid: process.processIdentifier)
        startProxyIfEnabled()
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
    ///
    /// This blocks the main thread, and `restart()` inherits that. llama-server
    /// handles SIGTERM promptly so the usual cost is well under a second, but
    /// a wedged child can stall the menu for the full timeout.
    func terminateSynchronously(timeout: TimeInterval = 2) {
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

    private func apply(events: [ServerLogScanner.Event], token: Int) {
        guard token == generation else { return }

        for event in events {
            switch event {
            case .ready:
                markReady(token: token)
            case .taskStarted:
                activeRequests += 1
            case .taskFinished:
                // Never below zero: the log may already have been mid-request
                // when we attached, and a dropped line should not wedge the
                // indicator on.
                activeRequests = max(0, activeRequests - 1)
            }
        }
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

    /// Puts the proxy in front of llama-server once the child is up.
    ///
    /// If this fails the endpoint is dead — llama-server is on the upstream
    /// port and nothing is on the public one — so say so plainly and name the
    /// way out, which does not need a rebuild.
    private func startProxyIfEnabled() {
        guard Config.insightsEnabled else { return }

        // A bind conflict arrives through onFailure rather than by throwing:
        // NWListener reports it asynchronously once it has tried the port.
        proxy.onFailure = { message in
            ServerController.shared.handleProxyFailure(message)
        }
        do {
            try proxy.start(port: Config.port, upstreamPort: Config.upstreamPort)
        } catch {
            handleProxyFailure(error.localizedDescription)
        }
    }

    /// The endpoint is down when this happens — llama-server is on the upstream
    /// port and nothing is on the public one — so name the way out, which does
    /// not need a rebuild.
    private func handleProxyFailure(_ message: String) {
        proxy.stop()
        state = .failed(
            "Port \(Config.port) unavailable (\(message)). Turn Insights off in Settings, "
            + "or: defaults write com.rosybit.app insightsEnabled -bool false")
    }

    private func cleanUp() {
        proxy.onFailure = nil
        proxy.stop()
        // Invalidate anything still in flight from the run being torn down.
        generation += 1

        if let current = process, let pipe = current.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminationHandler = nil
        process = nil
        activeRequests = 0

        // Deliberately not closed here. Clearing readabilityHandler does not
        // wait for a block that is already running, and that block may be
        // mid-write; closing underneath it would risk writing to a descriptor
        // the kernel has since handed to something else. Dropping our reference
        // lets the handle close on deinit once the last writer lets go. Writes
        // are unbuffered, so nothing is lost by waiting.
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
