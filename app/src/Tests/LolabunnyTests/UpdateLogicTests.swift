import Foundation
import Testing
@testable import Lolabunny

@MainActor
struct UpdateLogicTests {
    private func makeAsset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(
            name: name,
            downloadURL: URL(string: "https://example.com/\(name)")!
        )
    }

    @Test func selectReleaseAssetsTrimsReleaseVersion() {
        let app = AppDelegate()
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let checksum = archive + ".sha256"
        let release = ReleaseInfo(
            version: " v1.2.3 \n",
            assets: [makeAsset(archive), makeAsset(checksum)]
        )

        let selection = app.selectReleaseAssets(from: release)
        #expect(selection?.version == "v1.2.3")
    }

    @Test func selectReleaseAssetsReturnsUniversalArchiveWithChecksum() {
        let app = AppDelegate()
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let checksum = archive + ".sha256"
        let release = ReleaseInfo(
            version: "v1.2.3",
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
        let release = ReleaseInfo(
            version: "v1.2.3",
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

    @Test func versionMatchAllowsUnknownRequiredMajor() {
        let app = AppDelegate()
        #expect(app.versionMatchesRequiredMajor("v0.5.2", requiredMajor: ""))
        #expect(app.versionMatchesRequiredMajor("v2.1.0", requiredMajor: " "))
    }

    @Test func bootstrapPermissionMessageWithoutMajorIsReadable() {
        #expect(
            Config.Notification.serverBootstrapPermissionMessage(requiredMajor: "") ==
                "Download compatible server now?"
        )
    }

    @Test func parseExpectedSHA256ExtractsArchiveHash() {
        let app = AppDelegate()
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let hash = String(repeating: "a", count: 64)
        let contents = "\(hash) *\(archive)\n"

        #expect(app.parseExpectedSHA256(contents: contents, archiveName: archive) == hash)
    }

    @Test func archiveEntryOutputURLRejectsTraversal() {
        let app = AppDelegate()
        let baseDir = URL(fileURLWithPath: "/tmp/lolabunny-tests", isDirectory: true)

        let safe = app.archiveEntryOutputURL(baseDir: baseDir, entryName: "./bin/lolabunny")
        #expect(safe?.path == baseDir.appendingPathComponent("bin/lolabunny").path)

        let blocked = app.archiveEntryOutputURL(baseDir: baseDir, entryName: "../etc/passwd")
        #expect(blocked == nil)
    }
}
