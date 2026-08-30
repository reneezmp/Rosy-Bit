import Darwin
import Foundation
import XCTest
@testable import RosyBit

final class ProxyServerTests: XCTestCase {

    func testRelaysHTTPBytesOverLoopback() throws {
        let upstream = try OneShotHTTPServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nrosy!")
        defer { upstream.stop() }

        let received = expectation(description: "upstream received request")
        upstream.onRequest = { request in
            XCTAssertTrue(request.hasPrefix("GET /health HTTP/1.1\r\n"))
            received.fulfill()
        }
        upstream.start()

        let proxy = ProxyServer()
        try proxy.start(port: 0, upstreamPort: upstream.port)
        defer { proxy.stop() }

        let port = try XCTUnwrap(proxy.listeningPort)
        let response = try Self.request(
            "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
            port: port)

        XCTAssertEqual(
            response,
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nrosy!")
        wait(for: [received], timeout: 2)
    }

    func testKeepsConnectionOpenWhileKeepAliveClientWaitsForResponse() throws {
        let upstream = try OneShotHTTPServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
            responseDelayMicroseconds: 50_000)
        defer { upstream.stop() }
        upstream.start()

        let proxy = ProxyServer()
        try proxy.start(port: 0, upstreamPort: upstream.port)
        defer { proxy.stop() }

        let response = try Self.request(
            "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n",
            port: try XCTUnwrap(proxy.listeningPort),
            halfCloseAfterRequest: false)

        XCTAssertEqual(
            response,
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    }

    func testCanStopAndImmediatelyRebindSamePort() throws {
        let proxy = ProxyServer()
        try proxy.start(port: 0, upstreamPort: 11_337)
        let port = try XCTUnwrap(proxy.listeningPort)

        proxy.stop()
        try proxy.start(port: port, upstreamPort: 11_337)
        XCTAssertEqual(proxy.listeningPort, port)
        proxy.stop()
    }

    func testRealBindCollisionThrowsSynchronously() throws {
        let occupied = try BoundLoopbackSocket()
        defer { occupied.close() }

        let proxy = ProxyServer()
        XCTAssertThrowsError(try proxy.start(port: occupied.port, upstreamPort: 11_337)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("bind failed"), message)
            XCTAssertTrue(message.contains("errno \(EADDRINUSE)"), message)
        }
    }

    private static func request(
        _ request: String,
        port: Int,
        halfCloseAfterRequest: Bool = true
    ) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketTestError(operation: "socket", code: errno) }
        defer { Darwin.close(fd) }
        try setTimeouts(fd)

        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw SocketTestError(operation: "connect", code: errno) }

        try sendAll(Data(request.utf8), fd: fd)
        if halfCloseAfterRequest { shutdown(fd, SHUT_WR) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw SocketTestError(operation: "recv", code: errno)
            }
        }
        return String(decoding: response, as: UTF8.self)
    }
}

private final class OneShotHTTPServer {
    var onRequest: ((String) -> Void)?
    let port: Int

    private let response: Data
    private let responseDelayMicroseconds: useconds_t
    private let listener: BoundLoopbackSocket
    private let queue = DispatchQueue(label: "com.rosybit.tests.upstream")

    init(response: String, responseDelayMicroseconds: useconds_t = 0) throws {
        listener = try BoundLoopbackSocket()
        port = listener.port
        self.response = Data(response.utf8)
        self.responseDelayMicroseconds = responseDelayMicroseconds
    }

    func start() {
        queue.async { [self] in
            let clientFD = Darwin.accept(listener.fd, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            try? setTimeouts(clientFD)

            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = Darwin.recv(clientFD, &buffer, buffer.count, 0)
                if count > 0 {
                    request.append(contentsOf: buffer[0..<count])
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }

            onRequest?(String(decoding: request, as: UTF8.self))
            if responseDelayMicroseconds > 0 { usleep(responseDelayMicroseconds) }
            try? sendAll(response, fd: clientFD)
            shutdown(clientFD, SHUT_WR)
        }
    }

    func stop() {
        listener.close()
    }
}

private final class BoundLoopbackSocket {
    let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var isClosed = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketTestError(operation: "socket", code: errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = loopbackAddress(port: 0)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketTestError(operation: "bind/listen", code: code)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketTestError(operation: "getsockname", code: code)
        }

        self.fd = fd
        port = Int(UInt16(bigEndian: bound.sin_port))
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    deinit { close() }
}

private struct SocketTestError: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation): \(String(cString: strerror(code))) (errno \(code))"
    }
}

private func loopbackAddress(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

private func setTimeouts(_ fd: Int32) throws {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                     socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                     socklen_t(MemoryLayout<timeval>.size)) == 0 else {
        throw SocketTestError(operation: "setsockopt", code: errno)
    }
}

private func sendAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            if count > 0 {
                sent += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw SocketTestError(operation: "send", code: errno)
            }
        }
    }
}
