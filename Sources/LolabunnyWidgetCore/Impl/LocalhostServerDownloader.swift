import Foundation

struct LocalhostServerDownloader: ServerDownloader {
    private let streamDelayMillis: UInt64
    private static let defaultChunkSize = 64 * 1024

    init(streamDelayMillis: UInt64 = 0) {
        self.streamDelayMillis = streamDelayMillis
    }

    func download(
        from sourceURL: URL
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let requestedURL = sourceURL.standardizedFileURL
        guard requestedURL.isFileURL else {
            throw ServerDownloadError(what: "invalid local file URL")
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ServerDownloadError(what: "local archive file not found")
        }

        return makeFileChunks(
            fileURL: requestedURL,
            chunkSize: Self.defaultChunkSize,
            streamDelayMillis: streamDelayMillis
        )
    }

    private func makeFileChunks(
        fileURL: URL,
        chunkSize: Int,
        streamDelayMillis: UInt64
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }

                    while !Task.isCancelled {
                        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                        guard !chunk.isEmpty else {
                            break
                        }

                        continuation.yield(chunk)

                        if streamDelayMillis > 0 {
                            try await Task.sleep(nanoseconds: streamDelayMillis * 1_000_000)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

}
