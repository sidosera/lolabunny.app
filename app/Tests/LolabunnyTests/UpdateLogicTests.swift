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
        #expect(app.compareVersions("v1.1-beta+1", "v1.0.1-beta+10") == .orderedDescending)
        #expect(app.compareVersions("v1.2", "v1.2.0-beta+99") == .orderedSame)
        #expect(app.parseSemVer("v1.7-beta+99") == SemVer(major: 1, minor: 7, patch: 0))
        #expect(app.parseSemVer("invalid") == nil)
    }

    @Test func latestCompatibleUpdateVersionOnlyReturnsNewerVersion() {
        let app = AppDelegate()
        let candidates = [" v1.2.1 \n", "v1.2.0", "v1.1.9"]

        #expect(
            app.latestCompatibleUpdateVersion(
                currentVersion: "v1.2.0",
                latestVersions: candidates
            ) == "v1.2.1"
        )
        #expect(
            app.latestCompatibleUpdateVersion(
                currentVersion: "v1.2.1",
                latestVersions: candidates
            ) == nil
        )
        #expect(
            app.latestCompatibleUpdateVersion(
                currentVersion: "v1.2.2",
                latestVersions: candidates
            ) == nil
        )
    }

    @Test func updateMenuVersionTextLooksReadable() {
        let app = AppDelegate()
        #expect(
            app.updateMenuVersionText(updateVersion: "v1.2.1") ==
                "Update Now v1.2.1"
        )
    }

    @Test func updateMenuVersionTextCompactsSuffixes() {
        let app = AppDelegate()
        #expect(
            app.updateMenuVersionText(updateVersion: "v1.1-beta+1") ==
                "Update Now v1.1"
        )
    }

    @Test func versionMatchAllowsUnknownRequiredMajor() {
        let app = AppDelegate()
        #expect(app.versionMatchesRequiredMajor("v0.5.2", requiredMajor: ""))
        #expect(app.versionMatchesRequiredMajor("v2.1.0", requiredMajor: " "))
        #expect(app.versionMatchesRequiredMajor("v0.5.2-beta+1", requiredMajor: "alpha"))
    }

    @Test func bootstrapPermissionMessageWithoutMajorIsReadable() {
        #expect(
            Config.Notification.backendBootstrapPermissionMessage(requiredMajor: "") ==
                "Download compatible backend now?"
        )
    }

    @Test func downloadBackendNowImmediatelyShowsProgressState() {
        let app = AppDelegate()
        app.backendSetupState = .waitingForDownloadPermission(requiredMajor: "1")

        app.downloadBackendNow()

        guard case .downloading(let phase, let progress) = app.backendSetupState else {
            Issue.record("Expected .downloading state immediately after clicking download.")
            return
        }
        #expect(phase == "Preparing")
        #expect(progress > 0.0)
    }

    @Test func parseExpectedSHA256ExtractsArchiveHash() {
        let archive = "lolabunny-v1.2.3-darwin-universal.tar.gz"
        let hash = String(repeating: "a", count: 64)
        let contents = "\(hash) *\(archive)\n"

        #expect(
            BackendArchiveUtils.parseExpectedSHA256(
                contents: contents,
                archiveName: archive
            ) == hash
        )
    }

    @Test func archiveEntryOutputURLRejectsTraversal() {
        let baseDir = URL(fileURLWithPath: "/tmp/lolabunny-tests", isDirectory: true)

        let safe = BackendArchiveUtils.archiveEntryOutputURL(
            baseDir: baseDir,
            entryName: "./bin/lolabunny"
        )
        #expect(safe?.path == baseDir.appendingPathComponent("bin/lolabunny").path)

        let blocked = BackendArchiveUtils.archiveEntryOutputURL(
            baseDir: baseDir,
            entryName: "../etc/passwd"
        )
        #expect(blocked == nil)
    }

    @Test func backendBinaryLayoutIsFlatByVersion() {
        let app = AppDelegate()
        let binary = app.backendBinary(for: "v1.2.3")
        let locked = app.lockedBackendBinary(for: "v1.2.3")

        #expect(binary.lastPathComponent == Config.appName)
        #expect(binary.deletingLastPathComponent().lastPathComponent == "v1.2.3")
        #expect(locked.deletingLastPathComponent().lastPathComponent == "v1.2.3.locked")
    }

    @Test func unlockedVersionNameParsesLockedEntries() {
        let app = AppDelegate()
        #expect(app.unlockedVersionName(fromLockedEntry: "v1.2.3.locked") == "v1.2.3")
        #expect(app.unlockedVersionName(fromLockedEntry: "v1.2.3") == nil)
        #expect(app.unlockedVersionName(fromLockedEntry: ".locked") == nil)
    }
}
