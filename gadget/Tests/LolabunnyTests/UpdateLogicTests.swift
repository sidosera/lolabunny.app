import Foundation
import Testing
@testable import Lolabunny

@MainActor
struct UpdateLogicTests {
    private func makeAsset(_ name: String) -> GitHubAsset {
        GitHubAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")!
        )
    }

    @Test func gitHubReleaseDecodingMapsSnakeCaseFields() throws {
        let payload = """
        {
          "tag_name": "v1.2.3",
          "assets": [
            {
              "name": "lolabunny-v1.2.3-darwin-universal.tar.gz",
              "browser_download_url": "https://example.com/archive.tar.gz"
            }
          ]
        }
        """

        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(payload.utf8))
        #expect(release.tagName == "v1.2.3")
        #expect(release.assets.first?.browserDownloadURL.absoluteString == "https://example.com/archive.tar.gz")
    }

    @Test func selectReleaseAssetsReturnsUniversalArchiveWithChecksum() {
        let app = AppDelegate()
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let checksum = archive + ".sha256"
        let release = GitHubRelease(
            tagName: "v1.2.3",
            assets: [makeAsset(archive), makeAsset(checksum)]
        )

        let selection = app.selectReleaseAssets(from: release)
        #expect(selection?.archive.name == archive)
        #expect(selection?.checksum.name == checksum)
        #expect(selection?.version == "v1.2.3")
    }

    @Test func selectReleaseAssetsRequiresChecksum() {
        let app = AppDelegate()
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let release = GitHubRelease(
            tagName: "v1.2.3",
            assets: [makeAsset(archive)]
        )

        #expect(app.selectReleaseAssets(from: release) == nil)
    }

    @Test func versionComparisonUnderstandsSemver() {
        let app = AppDelegate()

        #expect(app.compareVersions("v1.2.10", "v1.2.9") == .orderedDescending)
        #expect(app.compareVersions("v1.2.9", "v1.2.10") == .orderedAscending)
        #expect(app.compareVersions("v1.2.9", "1.2.9") == .orderedSame)
        #expect(app.parseSemVer("invalid") == nil)
    }

    @Test func parseExpectedSHA256ExtractsArchiveHash() {
        let app = AppDelegate()
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let hash = String(repeating: "a", count: 64)
        let contents = "\(hash) *\(archive)\n"

        #expect(app.parseExpectedSHA256(contents: contents, archiveName: archive) == hash)
    }
}
