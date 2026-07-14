import Foundation

struct HttpServerDownloader: ServerDownloader {
    private let session: URLSession
    private let chunkSize: Int
    private let userAgent: String?

    init(
        session: URLSession = .shared,
        chunkSize: Int = 64 * 1024,
        userAgent: String? = nil
    ) {
        self.session = session
        self.chunkSize = chunkSize
        self.userAgent = userAgent
    }

    func download(
        from sourceURL: URL
    ) async throws -> AsyncThrowingStream<Data, Error> {
        var urlRequest = URLRequest(url: sourceURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        // The payload is already a .tar.gz archive. Request identity to avoid extra encoding layers.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let userAgent {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw ServerDownloadError(what: "widget-server unreachable")
        }

        guard 200..<300 ~= http.statusCode else {
            throw ServerDownloadError(what: "widget-server returned: \(http.statusCode)")
        }

        return makeStreamingChunks(
            bytes: bytes,
            chunkSize: chunkSize
        )
    }

    private func makeStreamingChunks(
        bytes: URLSession.AsyncBytes,
        chunkSize: Int
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var iterator = bytes.makeAsyncIterator()
                    var buffer = Data()
                    buffer.reserveCapacity(chunkSize)

                    while let byte = try await iterator.next() {
                        buffer.append(byte)

                        if buffer.count >= chunkSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    if !buffer.isEmpty {
                        continuation.yield(buffer)
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
