import Darwin
import Foundation

/// A loopback TCP proxy sitting in front of llama-server so Rosy Bit can see
/// the traffic it forwards.
///
/// This deliberately uses BSD sockets rather than `NWListener`. Ventura can
/// reject a Network.framework listener constrained to a specific loopback
/// endpoint with EADDRINUSE even when a direct bind proves the port is free.
/// Binding the socket ourselves also makes the security boundary unambiguous:
/// the kernel accepts traffic only on 127.0.0.1.
///
/// The proxy remains a byte pipe. Bytes are relayed as they arrive and copied
/// to the parser on the side; parsing never delays or changes what is sent.
/// Blocking reads and writes run on worker queues, which gives each direction
/// natural backpressure without buffering an unbounded streamed response.
final class ProxyServer {

    /// Reports a terminal listener failure after startup. Bind and listen
    /// failures are synchronous and throw directly from `start`.
    var onFailure: ((String) -> Void)?

    private var listenerSource: DispatchSourceRead?
    private var listenerClosed: DispatchSemaphore?
    private(set) var listeningPort: Int?

    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private let sessionsLock = NSLock()

    private let acceptQueue = DispatchQueue(label: "com.rosybit.proxy.accept", qos: .userInitiated)

    /// Starts listening on `port` and forwarding to `upstreamPort`.
    /// Passing zero is useful to tests and asks the kernel for an unused port.
    func start(port: Int, upstreamPort: Int) throws {
        stop()

        guard (0...65535).contains(port), (1...65535).contains(upstreamPort) else {
            throw ProxyError.invalidPort
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ProxyError.systemCall("socket", errno) }

        do {
            try Self.configureListener(fd: fd, port: port)
        } catch {
            Darwin.close(fd)
            throw error
        }

        let actualPort: Int
        do {
            actualPort = try Self.boundPort(of: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        let closed = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableClients(listenerFD: fd, upstreamPort: upstreamPort)
        }
        source.setCancelHandler {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            closed.signal()
        }

        listenerClosed = closed
        listenerSource = source
        listeningPort = actualPort
        source.resume()
    }

    func stop() {
        if let source = listenerSource, let closed = listenerClosed {
            listenerSource = nil
            listenerClosed = nil
            listeningPort = nil
            source.cancel()
            // The accept source is non-blocking and its handlers are tiny. Wait
            // for the descriptor to close so an immediate restart can rebind.
            closed.wait()
        }

        closeActiveSessions()
    }

    /// Drops every in-flight connection while leaving the listener up.
    ///
    /// This is how a runaway generation gets stopped. llama-server abandons a
    /// slot when the connection it is streaming into goes away.
    @discardableResult
    func closeActiveSessions() -> Int {
        sessionsLock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        sessionsLock.unlock()

        active.forEach { $0.close() }
        return active.count
    }

    private static func configureListener(fd: Int32, port: Int) throws {
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ProxyError.systemCall("setsockopt", errno)
        }

        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ProxyError.systemCall("setsockopt", errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(Config.host)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ProxyError.systemCall("bind", errno) }
        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            throw ProxyError.systemCall("listen", errno)
        }

        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ProxyError.systemCall("fcntl", errno)
        }
    }

    private static func boundPort(of fd: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { throw ProxyError.systemCall("getsockname", errno) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func acceptAvailableClients(listenerFD: Int32, upstreamPort: Int) {
        while true {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD >= 0 {
                guard Self.configureAcceptedClient(fd: clientFD) else {
                    Darwin.close(clientFD)
                    continue
                }
                accept(clientFD: clientFD, upstreamPort: upstreamPort)
                continue
            }

            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EBADF || errno == EINVAL { return } // listener stopped

            let message = ProxyError.systemCall("accept", errno).localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
            return
        }
    }

    private static func configureAcceptedClient(fd: Int32) -> Bool {
        // On Darwin an accepted socket can inherit O_NONBLOCK from its listener.
        // The relay workers deliberately use blocking I/O for backpressure; if
        // this flag remains set, the first temporary lack of request bytes is
        // EAGAIN and looks like a dropped connection to URLSession.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            return false
        }

        var noSignal: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                          socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func accept(clientFD: Int32, upstreamPort: Int) {
        guard let upstreamFD = Self.connectToUpstream(port: upstreamPort) else {
            shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
            return
        }

        let session = ProxySession(clientFD: clientFD, upstreamFD: upstreamFD)
        let token = ObjectIdentifier(session)

        sessionsLock.lock()
        sessions[token] = session
        sessionsLock.unlock()

        session.onFinish = { [weak self] in
            guard let self else { return }
            self.sessionsLock.lock()
            self.sessions.removeValue(forKey: token)
            self.sessionsLock.unlock()
        }
        session.start()
    }

    private static func connectToUpstream(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }

        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(Config.host)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    enum ProxyError: LocalizedError {
        case invalidPort
        case systemCall(String, Int32)

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                return "Invalid port number"
            case .systemCall(let operation, let code):
                return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }
}

/// One client socket and its matching upstream socket, pumped in both
/// directions until either side closes or fails.
private final class ProxySession {

    var onFinish: (() -> Void)?

    private let clientFD: Int32
    private let upstreamFD: Int32
    private let parser = HTTPTrafficParser()
    private let parserLock = NSLock()
    private let finishLock = NSLock()

    /// Holds itself alive while the two worker blocks are in flight.
    private var selfReference: ProxySession?
    private var finished = false
    private var activePumps = 2

    init(clientFD: Int32, upstreamFD: Int32) {
        self.clientFD = clientFD
        self.upstreamFD = upstreamFD

        parser.onRecord = { record in
            DispatchQueue.main.async { InsightsStore.shared.record(record) }
        }
    }

    func start() {
        selfReference = self

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: clientFD, to: upstreamFD, isRequest: true)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: upstreamFD, to: clientFD, isRequest: false)
        }
    }

    func close() {
        finish()
    }

    private func pump(from sourceFD: Int32, to destinationFD: Int32, isRequest: Bool) {
        defer { pumpDidExit() }
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            guard !isFinished else { return }
            let count = Darwin.recv(sourceFD, &buffer, buffer.count, 0)
            if count > 0 {
                let data = Data(buffer[0..<count])
                parserLock.lock()
                if isRequest {
                    parser.consumeRequest(data)
                } else {
                    parser.consumeResponse(data)
                }
                parserLock.unlock()

                guard Self.sendAll(data, to: destinationFD) else {
                    finish()
                    return
                }
                continue
            }

            if count == 0 {
                if isRequest {
                    // Preserve the response half when a client has finished
                    // sending its request body.
                    shutdown(destinationFD, SHUT_WR)
                } else {
                    shutdown(destinationFD, SHUT_WR)
                    finish()
                }
                return
            }

            if errno == EINTR { continue }
            finish()
            return
        }
    }

    private static func sendAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func finish() {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        let callback = onFinish
        onFinish = nil
        finishLock.unlock()

        // Wake both blocking recv/send loops, but do not close the numeric file
        // descriptors until both workers have exited. Closing earlier would let
        // the kernel reuse a descriptor while the other worker still holds it.
        shutdown(clientFD, SHUT_RDWR)
        shutdown(upstreamFD, SHUT_RDWR)

        callback?()
    }

    private var isFinished: Bool {
        finishLock.lock()
        let value = finished
        finishLock.unlock()
        return value
    }

    private func pumpDidExit() {
        finishLock.lock()
        activePumps -= 1
        let shouldClose = activePumps == 0
        if shouldClose { selfReference = nil }
        finishLock.unlock()

        guard shouldClose else { return }
        Darwin.close(clientFD)
        Darwin.close(upstreamFD)
    }
}
