import Foundation
import ReMeetKit

/// Downloads a Hugging Face model repository into a local folder with byte-level progress.
/// Files already complete (same size) are skipped, so a quit or network drop resumes at the
/// file that was in flight. Each file lands under a temporary name first.
final class HFDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum DownloadError: LocalizedError {
        case http(Int, String)
        case listing(String)
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let file): "Download of \(file) failed (HTTP \(code))."
            case .listing(let repo): "Could not list the files of \(repo)."
            case .denied(let repo):
                "Hugging Face refused access to \(repo). The model may have moved; check huggingface.co/\(repo)."
            }
        }
    }

    /// Hugging Face read token for gated repositories. No current model needs one. Sent only
    /// to huggingface.co in the Authorization header; never logged.
    var token: String?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var currentBytes: Int64 = 0
    private var onBytes: ((Int64) -> Void)?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    static func fileURL(repo: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
    }

    func listFiles(repo: String) async throws -> [RemoteFile] {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!)
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw DownloadError.denied(repo) }
        guard status == 200 else { throw DownloadError.listing(repo) }
        return try DownloadPlan.parseTree(data)
    }

    private func authorize(_ request: inout URLRequest) {
        guard let token, !token.isEmpty, request.url?.host == "huggingface.co" else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Downloads every file of `repo` into `directory`. `progress` gets 0...1.
    func download(repo: String, into directory: URL, include: (String) -> Bool = { _ in true },
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(repo: repo, into: directory, map: { include($0) ? $0 : nil }, progress: progress)
    }

    /// `map` turns a repository path into the local path to save it as (nil = skip it).
    func download(repo: String, into directory: URL, map: (String) -> String?,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var localPath: [String: String] = [:]
        var remote: [RemoteFile] = []
        for file in try await listFiles(repo: repo) {
            guard let local = map(file.path) else { continue }
            localPath[file.path] = local
            remote.append(file)
        }
        let plan = DownloadPlan.make(remote: remote) { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(localPath[path] ?? path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value
        }
        // The session holds its delegate (self) strongly; end it when this download ends (audit L4).
        defer { session.finishTasksAndInvalidate() }
        var finished: Int64 = 0
        progress(plan.fraction(fetchedBytes: 0))
        for file in plan.toFetch {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(localPath[file.path] ?? file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = finished
            let temp = try await fetch(Self.fileURL(repo: repo, path: file.path), name: file.path) { bytes in
                progress(plan.fraction(fetchedBytes: base + bytes))
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            finished += file.size
            progress(plan.fraction(fetchedBytes: finished))
        }
    }

    private func fetch(_ url: URL, name: String, onBytes: @escaping (Int64) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        authorize(&request)
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.onBytes = onBytes
                    self.currentName = name
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private var currentName = ""

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let handler = lock.withLock { onBytes }
        handler?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let (continuation, name) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, String) in
            defer { self.continuation = nil }
            return (self.continuation, currentName)
        }
        guard let continuation else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            continuation.resume(throwing: DownloadError.denied(name))
            return
        }
        guard status == 200 else {
            continuation.resume(throwing: DownloadError.http(status, name))
            return
        }
        // The system deletes `location` when this returns, so move it somewhere of ours now.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            continuation.resume(returning: keep)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
    }
}
