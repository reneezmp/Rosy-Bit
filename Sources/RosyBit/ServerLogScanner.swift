import Foundation

/// Reads meaning out of llama-server's own output as it streams past on its way
/// to the log file.
///
/// This is why the app needs no polling at all: the server already announces
/// when it starts listening and when it picks up and finishes each request, so
/// readiness and in-flight work both come for free from bytes we are handling
/// anyway.
///
/// Only ever touched from the pipe's reader queue.
final class ServerLogScanner {

    enum Event {
        /// The server is accepting connections.
        case ready
        /// A slot picked up a request.
        case taskStarted
        /// A slot finished one.
        case taskFinished
    }

    /// Wording has drifted between llama.cpp releases, so match several.
    private static let readyMarkers = [
        "server is listening",
        "starting the main loop",
        "HTTP server listening",
    ]

    private var buffer = Data()
    private var announcedReady = false

    func consume(_ data: Data) -> [Event] {
        buffer.append(data)

        var events: [Event] = []
        // Split on newline *bytes* rather than decoding the chunk as a whole:
        // a read can land mid-character, and decoding the whole chunk would
        // then fail and discard a line that was only half delivered. 0x0A never
        // occurs inside a multi-byte UTF-8 sequence, so this is always safe.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer = buffer.subdata(in: (newline + 1)..<buffer.endIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let event = classify(line) {
                events.append(event)
            }
        }

        // A pathological line with no newline must not grow without bound.
        if buffer.count > 8192 {
            buffer = buffer.subdata(in: (buffer.count - 4096)..<buffer.count)
        }
        return events
    }

    private func classify(_ line: String) -> Event? {
        if !announcedReady, Self.readyMarkers.contains(where: line.contains) {
            announcedReady = true
            return .ready
        }
        // "launch_slot_: id 3 | task 0 | processing task, is_child = 0"
        if line.contains("launch_slot_"), line.contains("processing task") {
            return .taskStarted
        }
        // "release: id 3 | task 0 | stop processing: n_tokens = 34, ..."
        if line.contains("stop processing") {
            return .taskFinished
        }
        return nil
    }
}
