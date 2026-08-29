import Foundation
import Network

/// A loopback TCP proxy sitting in front of llama-server so Rosy Bit can see
/// the traffic it forwards.
///
/// It is a byte pipe, deliberately. Bytes are relayed exactly as they arrive
/// and a copy is handed to a parser on the side; the parser has no say in
/// whether or when anything is forwarded. That matters for streaming above all
/// — an OpenAI client sending `"stream": true` expects Server-Sent Events to
/// arrive incrementally, and at 2 tok/s a buffered response would look
/// identical to a hang.
///
/// Backpressure comes from chaining: the next `receive` is only issued once the
/// previous `send` reports the data processed, so a slow reader cannot make
/// this accumulate an unbounded buffer.
final class ProxyServer {

    private(set) var isRunning = false

    private var listener: NWListener?
    private var connections = Set<ObjectIdentifier>()
    private var connectionsLock = NSLock()

    private let queue = DispatchQueue(label: "com.rosybit.proxy", qos: .userInitiated)

    /// Starts listening on `port` and forwarding to `upstreamPort`.
    /// Throws if the port cannot be bound.
    func start(port: Int, upstreamPort: Int) throws {
        stop()

        guard let listenPort = NWEndpoint.Port(rawValue: UInt16(port)),
              let targetPort = NWEndpoint.Port(rawValue: UInt16(upstreamPort)) else {
            throw ProxyError.invalidPort
        }

        let parameters = NWParameters.tcp
        // Loopback only, and stated rather than assumed: NWListener binds every
        // interface by default, and this machine goes to the courthouse.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: listenPort)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] client in
            self?.accept(client: client, upstreamPort: targetPort)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.isRunning = false
            case .ready:
                self?.isRunning = true
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(client: NWConnection, upstreamPort: NWEndpoint.Port) {
        let upstream = NWConnection(
            host: .ipv4(.loopback), port: upstreamPort, using: .tcp)

        let session = ProxySession(client: client, upstream: upstream, queue: queue)
        let token = ObjectIdentifier(session)

        connectionsLock.lock()
        connections.insert(token)
        connectionsLock.unlock()

        session.onFinish = { [weak self] in
            guard let self else { return }
            self.connectionsLock.lock()
            self.connections.remove(token)
            self.connectionsLock.unlock()
        }
        session.start()
    }

    enum ProxyError: LocalizedError {
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "Invalid port number"
            }
        }
    }
}

/// One client connection and its matching upstream connection, pumped in both
/// directions until either end goes away.
private final class ProxySession {

    var onFinish: (() -> Void)?

    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let parser = HTTPTrafficParser()

    /// Holds itself alive for the duration; released in `finish()`.
    private var selfReference: ProxySession?
    private var finished = false

    init(client: NWConnection, upstream: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.upstream = upstream
        self.queue = queue

        parser.onRecord = { record in
            DispatchQueue.main.async { InsightsStore.shared.record(record) }
        }
    }

    func start() {
        selfReference = self

        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Only start pumping once upstream can actually take bytes.
                self?.pumpClientToUpstream()
                self?.pumpUpstreamToClient()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }

        client.start(queue: queue)
        upstream.start(queue: queue)
    }

    private func pumpClientToUpstream() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.parser.consumeRequest(data)
                self.upstream.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        self.finish()
                    } else {
                        self.pumpClientToUpstream()
                    }
                })
                return
            }

            if isComplete {
                // The client is done sending; let upstream see EOF so it can
                // answer, but keep reading the response.
                self.upstream.send(content: nil, isComplete: true, completion: .idempotent)
                return
            }
            if error != nil { self.finish() } else { self.pumpClientToUpstream() }
        }
    }

    private func pumpUpstreamToClient() {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.parser.consumeResponse(data)
                self.client.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        self.finish()
                    } else {
                        self.pumpUpstreamToClient()
                    }
                })
                return
            }

            if isComplete || error != nil {
                self.client.send(content: nil, isComplete: true, completion: .idempotent)
                self.finish()
                return
            }
            self.pumpUpstreamToClient()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true

        client.stateUpdateHandler = nil
        upstream.stateUpdateHandler = nil
        client.cancel()
        upstream.cancel()

        onFinish?()
        onFinish = nil
        selfReference = nil
    }
}
