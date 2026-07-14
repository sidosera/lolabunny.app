import Foundation
import XCTest
@testable import LolabunnyWidgetCore

final class LocalhostServerDownloaderTests: XCTestCase {
    func testLocalhostDownloaderStreamsArchiveFile() async throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lolabunny-localhost-downloader-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let archiveName = "lolabunny-v9.9.9-darwin-universal.tar.gz"
        let archiveURL = tempDir.appendingPathComponent(archiveName)
        let expected = Data((0..<150_000).map { UInt8($0 % 251) })
        try expected.write(to: archiveURL, options: .atomic)

        let downloader = LocalhostServerDownloader(streamDelayMillis: 0)

        let stream = try await downloader.download(from: archiveURL)
        var actual = Data()
        for try await chunk in stream {
            actual.append(chunk)
        }

        XCTAssertTrue(actual == expected)
    }

    func testLocalhostDownloaderRejectsMissingFile() async {
        let downloader = LocalhostServerDownloader(streamDelayMillis: 0)
        let missing = URL(fileURLWithPath: "/tmp/lolabunny-missing-\(UUID().uuidString).tar.gz")

        do {
            _ = try await downloader.download(from: missing)
            XCTFail("Expected missing local archive to throw.")
        } catch {
            // Expected path.
        }
    }
}
