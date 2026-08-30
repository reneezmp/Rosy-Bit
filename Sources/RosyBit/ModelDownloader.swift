import Combine
import Foundation

/// Fetches the model on first run, so installing Rosy Bit does not also mean
/// running a shell script.
///
/// The model deliberately lives outside the app bundle — that is what lets it
/// be swapped without rebuilding — which leaves a gap on a fresh install that
/// this closes. It mirrors `scripts/fetch-model.sh`: ask the Hugging Face API
/// which files exist rather than guessing the filename, download to a temporary
/// location, and only move it into place once it is verified.
///
/// Main thread only; the session delivers its callbacks there.
final class ModelDownloader: NSObject, ObservableObject {

    static let shared = ModelDownloader()

    enum State: Equatable {
        case idle
        case resolving
        case downloading(received: Int64, expected: Int64)
        case finished(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .resolving, .downloading: return true
            case .idle, .finished, .failed: return false
            }
        }
    }

    /// Carries a message meant to be read by a person, since every failure here
    /// ends up as text in the setup window.
    struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    @Published private(set) var state: State = .idle

    /// Called once a model has landed and been verified.
    var onInstalled: ((URL) -> Void)?

    private var task: URLSessionDownloadTask?
    private var pendingFilename: String?
    private var activeRepository = Config.modelRepository

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // A quarter of a gigabyte over whatever network is to hand. The default
        // resource timeout of 7 days is too generous; an hour is not.
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Control

    /// Which repository the current download is from, for the setup window to
    /// name while it runs.
    @Published private(set) var activeModelName: String?

    func start(repository: String = Config.modelRepository) {
        guard !state.isBusy else { return }
        activeRepository = repository
        activeModelName = Config.knownModels.first { $0.repository == repository }?.name
        state = .resolving
        resolveFilename { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let filename):
                self.beginDownload(of: filename)
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingFilename = nil
        state = .idle
    }

    // MARK: - Steps

    private func resolveFilename(completion: @escaping (Result<String, Failure>) -> Void) {
        let repository = activeRepository
        guard let url = URL(string: "https://huggingface.co/api/models/\(repository)") else {
            return completion(.failure(Failure("Invalid model repository: \(repository)")))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    return completion(.failure(Failure("Could not reach Hugging Face: \(error.localizedDescription)")))
                }
                guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                    return completion(.failure(Failure("Hugging Face returned an error for \(repository)")))
                }
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let siblings = object["siblings"] as? [[String: Any]] else {
                    return completion(.failure(Failure("Could not read the file list for \(repository)")))
                }

                let names = siblings.compactMap { $0["rfilename"] as? String }
                let ggufs = names.filter { $0.lowercased().hasSuffix(".gguf") }
                let wanted = Config.modelQuant.lowercased()
                guard let match = ggufs.first(where: { $0.lowercased().contains(wanted) }) ?? ggufs.first
                else {
                    return completion(.failure(Failure("No .gguf file found in \(repository)")))
                }
                completion(.success(match))
            }
        }.resume()
    }

    private func beginDownload(of filename: String) {
        let name = (filename as NSString).lastPathComponent
        let destination = Config.modelDirectory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            state = .finished(name)
            onInstalled?(destination)
            return
        }

        let escaped = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        guard let url = URL(
            string: "https://huggingface.co/\(activeRepository)/resolve/main/\(escaped)?download=true")
        else {
            state = .failed("Could not build a download URL for \(name)")
            return
        }

        pendingFilename = name
        state = .downloading(received: 0, expected: 0)

        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    /// A `.gguf` starts with the four bytes `GGUF`. Checking them turns a 404
    /// page or a truncated transfer into an error here, rather than a confusing
    /// failure deep inside llama-server later.
    private func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        state = .downloading(received: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file is removed as soon as this returns, so everything
        // here has to happen now rather than asynchronously.
        guard let name = pendingFilename else { return }
        pendingFilename = nil

        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            state = .failed("Download failed with HTTP \(status)")
            return
        }
        guard looksLikeGGUF(location) else {
            state = .failed("The downloaded file is not a GGUF model")
            return
        }

        let fileManager = FileManager.default
        let directory = Config.modelDirectory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)

        do {
            // Verified first, moved second: a partial or wrong file never
            // appears in the models folder under a name that looks finished.
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            state = .failed("Could not save the model: \(error.localizedDescription)")
            return
        }

        state = .finished(name)
        onInstalled?(destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.task = nil
        guard let error else { return }  // success already handled above

        if (error as NSError).code == NSURLErrorCancelled {
            state = .idle
            return
        }
        state = .failed(error.localizedDescription)
    }
}
