import Foundation

struct ServerDownloadError: Error {
    let what: String
}

protocol ServerDownloader: Sendable {
    func download(
        from sourceURL: URL
    ) async throws -> AsyncThrowingStream<Data, Error>
}
