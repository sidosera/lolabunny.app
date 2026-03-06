import CryptoKit
import Foundation
import SWCompression

struct DownloadBackendRequest: Sendable {
    let version: String
    let expectedSHA256Hex: String?
    let sourceURL: URL?

    init(version: String, expectedSHA256Hex: String?, sourceURL: URL? = nil) {
        self.version = version
        self.expectedSHA256Hex = expectedSHA256Hex
        self.sourceURL = sourceURL
    }
}

struct DownloadBackendResponse: Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
}

protocol BackendDownloader: Sendable {
    func download(request: DownloadBackendRequest) async throws -> DownloadBackendResponse
}

struct BackendDownloadError: Error {
    let what: String
}

struct HttpBackendDownloader: BackendDownloader {
    private let session: URLSession
    private let baseURL: URL
    private let chunkSize: Int
    private let userAgent: String?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        chunkSize: Int = 64 * 1024,
        userAgent: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.chunkSize = chunkSize
        self.userAgent = userAgent
    }

    func download(request: DownloadBackendRequest) async throws -> DownloadBackendResponse {
        let url = try makeURL(for: request)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let userAgent {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw BackendDownloadError(what: "server unreachable")
        }

        guard 200..<300 ~= http.statusCode else {
            throw BackendDownloadError(what: "server returned: \(http.statusCode)")
        }

        let responseEncoding = http.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch responseEncoding {
        case "gzip":
            return DownloadBackendResponse(
                chunks: makeBufferedGzipDecompressedChunks(
                    bytes: bytes,
                    chunkSize: chunkSize,
                    expectedSHA256Hex: request.expectedSHA256Hex
                )
            )
        default:
            return DownloadBackendResponse(
                chunks: makeStreamingChunks(
                    bytes: bytes,
                    chunkSize: chunkSize,
                    expectedSHA256Hex: request.expectedSHA256Hex
                )
            )
        }
    }

    private func makeURL(for request: DownloadBackendRequest) throws -> URL {
        if let sourceURL = request.sourceURL {
            return sourceURL
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "version", value: request.version)
        ]

        guard let url = components?.url else {
            throw BackendDownloadError(what: "invalid URL")
        }
        return url
    }

    private func makeStreamingChunks(
        bytes: URLSession.AsyncBytes,
        chunkSize: Int,
        expectedSHA256Hex: String?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var iterator = bytes.makeAsyncIterator()
                    var buffer = Data()
                    buffer.reserveCapacity(chunkSize)

                    var hasher = SHA256()
                    while let byte = try await iterator.next() {
                        buffer.append(byte)

                        if buffer.count >= chunkSize {
                            hasher.update(data: buffer)
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    if !buffer.isEmpty {
                        hasher.update(data: buffer)
                        continuation.yield(buffer)
                    }

                    let actualHash = hasher.finalize().hexString
                    try verifyChecksum(
                        expectedSHA256Hex: expectedSHA256Hex,
                        actualSHA256Hex: actualHash
                    )

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

    private func makeBufferedGzipDecompressedChunks(
        bytes: URLSession.AsyncBytes,
        chunkSize: Int,
        expectedSHA256Hex: String?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var iterator = bytes.makeAsyncIterator()
                    var compressed = Data()
                    compressed.reserveCapacity(chunkSize)

                    while let byte = try await iterator.next() {
                        compressed.append(byte)
                    }

                    let actualHash = SHA256.hash(data: compressed).hexString
                    try verifyChecksum(
                        expectedSHA256Hex: expectedSHA256Hex,
                        actualSHA256Hex: actualHash
                    )

                    // SWCompression supports gzip decompression on Data.
                    let decompressed = try GzipArchive.unarchive(archive: compressed)

                    var offset = 0
                    while offset < decompressed.count {
                        let end = min(offset + chunkSize, decompressed.count)
                        continuation.yield(decompressed.subdata(in: offset..<end))
                        offset = end
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

    private func verifyChecksum(
        expectedSHA256Hex: String?,
        actualSHA256Hex: String
    ) throws {
        guard let expectedSHA256Hex else {
            return
        }

        if expectedSHA256Hex.lowercased() != actualSHA256Hex.lowercased() {
            throw BackendDownloadError(what: "untrusted")
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
