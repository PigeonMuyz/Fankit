import Foundation

/// A dedicated session forwards download progress and owns its temporary file.
nonisolated final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    // Mutated only on URLSession's serial delegate queue after initialization.
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadedFile: URL?
    private var fileError: Error?

    private init(continuation: CheckedContinuation<(URL, URLResponse), Error>,
                 onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.continuation = continuation
        self.onProgress = onProgress
    }

    static func download(from url: URL,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = UpdateDownloadDelegate(continuation: continuation, onProgress: onProgress)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 30 * 60
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fankit-download-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedFile = destination
        } catch {
            fileError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            continuation = nil
            session.finishTasksAndInvalidate()
        }
        if let error = error ?? fileError {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
            continuation?.resume(throwing: error)
        } else if let downloadedFile, let response = task.response {
            continuation?.resume(returning: (downloadedFile, response))
        } else {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}
