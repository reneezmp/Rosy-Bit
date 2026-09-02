import Combine
import Foundation

/// Imports llama.cpp-ready GGUF files from Hugging Face without requiring a
/// terminal. A repository may contain many quantisations, so discovery and
/// download are separate steps: Rosy never guesses which large file to fetch.
final class HuggingFaceModelImporter: NSObject, ObservableObject {

    static let shared = HuggingFaceModelImporter()

    struct RemoteFile: Identifiable, Equatable {
        let path: String
        var id: String { path }
        var displayName: String { (path as NSString).lastPathComponent }
    }

    enum State: Equatable {
        case idle
        case resolving
        case ready
        case downloading(received: Int64, expected: Int64)
        case finished(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .resolving, .downloading: return true
            case .idle, .ready, .finished, .failed: return false
            }
        }
    }

    struct Source: Equatable {
        let repository: String
        let exactFile: String?
        let revision: String

        static func parse(_ input: String) -> Source? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if !trimmed.contains("://") {
                let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: true)
                guard pieces.count == 2, pieces.allSatisfy(validComponent) else { return nil }
                return Source(repository: pieces.joined(separator: "/"), exactFile: nil, revision: "main")
            }

            guard let url = URL(string: trimmed),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "huggingface.co" else { return nil }
            let pieces = url.pathComponents.filter { $0 != "/" }
            guard pieces.count >= 2,
                  validComponent(Substring(pieces[0])),
                  validComponent(Substring(pieces[1])) else { return nil }
            let repository = "\(pieces[0])/\(pieces[1])"

            if pieces.count >= 5,
               ["blob", "resolve"].contains(pieces[2]),
               pieces.dropFirst(4).joined(separator: "/").lowercased().hasSuffix(".gguf") {
                return Source(
                    repository: repository,
                    exactFile: pieces.dropFirst(4).joined(separator: "/"),
                    revision: pieces[3]
                )
            }
            return Source(repository: repository, exactFile: nil, revision: "main")
        }

        private static func validComponent(_ value: Substring) -> Bool {
            !value.isEmpty && value != "." && value != ".."
                && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var files: [RemoteFile] = []
    @Published var selectedPath: String = ""
    @Published private(set) var repository: String?
    private var revision = "main"

    var onInstalled: ((URL) -> Void)?

    private var resolutionTask: URLSessionDataTask?
    private var downloadTask: URLSessionDownloadTask?
    private var pendingFilename: String?
    private var generation = 0

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private override init() { super.init() }

    func reset() {
        cancel()
        files = []
        selectedPath = ""
        repository = nil
        revision = "main"
        state = .idle
    }

    func discover(_ input: String) {
        cancelTasks()
        files = []
        selectedPath = ""
        guard let source = Source.parse(input) else {
            state = .failed("Paste owner/repository, a Hugging Face repository link, or a direct .gguf link.")
            return
        }
        repository = source.repository
        revision = source.revision
        if let exact = source.exactFile {
            files = [RemoteFile(path: exact)]
            selectedPath = exact
            state = .ready
            return
        }

        state = .resolving
        generation += 1
        let token = generation
        let escaped = source.repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? source.repository
        guard let url = URL(string: "https://huggingface.co/api/models/\(escaped)") else {
            state = .failed("That Hugging Face repository address is not valid.")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        resolutionTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.resolutionTask = nil
                if let error {
                    self.state = .failed("Could not reach Hugging Face: \(error.localizedDescription)")
                    return
                }
                guard let status = (response as? HTTPURLResponse)?.statusCode else {
                    self.state = .failed("Hugging Face did not return a response.")
                    return
                }
                guard status == 200 else {
                    self.state = .failed(status == 404
                        ? "Hugging Face could not find that public repository."
                        : "Hugging Face returned HTTP \(status). Private and gated repositories are not supported yet.")
                    return
                }
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let siblings = object["siblings"] as? [[String: Any]] else {
                    self.state = .failed("Rosy could not read this repository's file list.")
                    return
                }
                let discovered = siblings
                    .compactMap { $0["rfilename"] as? String }
                    .filter { $0.lowercased().hasSuffix(".gguf") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map(RemoteFile.init(path:))
                guard !discovered.isEmpty else {
                    self.state = .failed(
                        "This is a valid Hugging Face repository, but it contains no GGUF files. "
                        + "Rosy's llama.cpp engine needs a GGUF edition of the model."
                    )
                    return
                }
                self.files = discovered
                self.selectedPath = discovered.first?.path ?? ""
                self.state = .ready
            }
        }
        resolutionTask?.resume()
    }

    func downloadSelected() {
        guard !state.isBusy, let repository, !selectedPath.isEmpty else { return }
        let filename = (selectedPath as NSString).lastPathComponent
        let destination = Config.modelDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            state = .finished(filename)
            onInstalled?(destination)
            return
        }
        let repo = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository
        let ref = revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? revision
        let file = selectedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedPath
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(ref)/\(file)?download=true") else {
            state = .failed("Rosy could not build the download address.")
            return
        }
        pendingFilename = filename
        state = .downloading(received: 0, expected: 0)
        let task = session.downloadTask(with: url)
        downloadTask = task
        task.resume()
    }

    func cancel() {
        cancelTasks()
        if state.isBusy { state = files.isEmpty ? .idle : .ready }
    }

    private func cancelTasks() {
        generation += 1
        resolutionTask?.cancel()
        resolutionTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        pendingFilename = nil
    }

    private func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

extension HuggingFaceModelImporter: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard self.downloadTask === downloadTask else { return }
        state = .downloading(received: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard self.downloadTask === downloadTask, let filename = pendingFilename else { return }
        pendingFilename = nil
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            state = .failed("Download failed with HTTP \(status).")
            return
        }
        guard looksLikeGGUF(location) else {
            state = .failed("The downloaded file is not a valid GGUF model.")
            return
        }
        let manager = FileManager.default
        try? manager.createDirectory(at: Config.modelDirectory, withIntermediateDirectories: true)
        let destination = Config.modelDirectory.appendingPathComponent(filename)
        do {
            try manager.moveItem(at: location, to: destination)
        } catch {
            state = .failed("Could not save the model: \(error.localizedDescription)")
            return
        }
        state = .finished(filename)
        onInstalled?(destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard downloadTask === task else { return }
        downloadTask = nil
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        state = .failed("Download failed: \(error.localizedDescription)")
    }
}
