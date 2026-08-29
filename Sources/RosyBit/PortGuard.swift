import Darwin
import Foundation

/// Gotcha #1: force-quit the app and `llama-server` keeps running, holding the
/// port. Cleanup happens in two places — `applicationWillTerminate` kills the
/// child we own, and this type handles the case where that did not happen.
///
/// The rule is: only ever kill a process actually named `llama-server`. Anything
/// else on the port (Osaurus on the M4, say) is reported, not fought.
enum PortGuard {

    enum Outcome {
        /// Port is free; nothing was in the way.
        case clear
        /// An orphaned `llama-server` was holding the port and has been killed.
        case clearedOrphan(pid: pid_t)
        /// Something we must not touch is on the port.
        case blocked(by: String)
    }

    /// How long to wait for a signalled process to actually exit, and for the
    /// kernel to release its socket afterwards. Both are on the main thread, so
    /// they are kept short — the common case touches neither.
    private static let processExitTimeout: TimeInterval = 1.5
    private static let portReleaseTimeout: TimeInterval = 0.75

    /// Makes `port` available for a server we are about to launch.
    static func prepare(port: Int, pidFile: URL) -> Outcome {
        var killed: pid_t?

        // Layer 1: a pidfile from a previous run of this app.
        if let pid = readPidFile(pidFile), isLlamaServer(pid) {
            terminate(pid)
            killed = pid
        }
        try? FileManager.default.removeItem(at: pidFile)

        // Only wait for the socket if we just killed something; otherwise this
        // is a single syscall.
        if waitForPortFree(port, timeout: killed == nil ? 0 : portReleaseTimeout) {
            return killed.map { Outcome.clearedOrphan(pid: $0) } ?? .clear
        }

        // Layer 2: the pidfile was missing or stale but the port is still held.
        guard let pid = pidHoldingPort(port) else {
            // Nothing is listening, yet the port would not bind. Rather than
            // report a port we may have just cleared ourselves, give the kernel
            // one more moment before giving up.
            if waitForPortFree(port, timeout: portReleaseTimeout) {
                return killed.map { Outcome.clearedOrphan(pid: $0) } ?? .clear
            }
            return .blocked(by: "another process")
        }

        let name = processName(pid) ?? "pid \(pid)"
        guard name == "llama-server" else {
            return .blocked(by: name)
        }

        terminate(pid)
        if waitForPortFree(port, timeout: portReleaseTimeout) {
            return .clearedOrphan(pid: pid)
        }
        return .blocked(by: name)
    }

    static func writePidFile(_ url: URL, pid: pid_t) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func waitForPortFree(_ port: Int, timeout: TimeInterval) -> Bool {
        if isPortFree(port) { return true }
        guard timeout > 0 else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(50_000)
            if isPortFree(port) { return true }
        }
        return false
    }

    /// True if nothing is listening — determined by trying to bind the port
    /// ourselves, exactly the way a server would.
    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }

        // Servers set SO_REUSEADDR, so this must too, or the question being
        // answered is the wrong one: connections the previous server handled
        // linger in TIME_WAIT on this port and would make a genuinely free port
        // look busy for a minute after every stop. SO_REUSEADDR still refuses
        // the bind while something is actively listening, which is what we want
        // to detect.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        addr.sin_addr.s_addr = inet_addr(Config.host)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Process inspection

    private static func isLlamaServer(_ pid: pid_t) -> Bool {
        isAlive(pid) && processName(pid) == "llama-server"
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 checks for existence without delivering anything. EPERM means
        // the process exists but belongs to someone else.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func processName(_ pid: pid_t) -> String? {
        guard let output = runTool("/bin/ps", ["-p", String(pid), "-o", "comm="]),
              !output.isEmpty else { return nil }
        return (output as NSString).lastPathComponent
    }

    private static func pidHoldingPort(_ port: Int) -> pid_t? {
        guard let output = runTool("/usr/sbin/lsof", ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]) else {
            return nil
        }
        return output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.first
    }

    private static func terminate(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(processExitTimeout)
        while Date() < deadline {
            if !isAlive(pid) { return }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
    }

    private static func readPidFile(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runTool(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
