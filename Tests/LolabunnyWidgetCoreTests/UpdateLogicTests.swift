import Foundation
import XCTest
@testable import LolabunnyWidgetCore

@MainActor
final class UpdateLogicTests: XCTestCase {
    func testCanonicalArchiveNameIncludesVersionAndExtension() {
        let widget = AppDelegate()
        let archiveName = widget.canonicalServerArchiveName(version: "v2.4.6")
        XCTAssertTrue(archiveName.contains("v2.4.6"))
        XCTAssertTrue(archiveName.hasPrefix("\(Config.serverExecutableName)-"))
        XCTAssertTrue(archiveName.hasSuffix(".tar.gz"))
    }

    func testUpdateSourceConfigIsAvailableInPackageRuntime() {
        let widget = AppDelegate()
        XCTAssertTrue(widget.isServerUpdateSourceConfigured())
    }

    func testParseReleaseTagFromResolvedURLReadsVersionFromTagPath() {
        let widget = AppDelegate()
        let url = URL(string: "https://example.com/releases/tag/v2.4.6")!
        XCTAssertTrue(widget.parseReleaseTagFromResolvedURL(url) == "v2.4.6")
    }

    func testParseReleaseTagFromResolvedURLRejectsNonTagPath() {
        let widget = AppDelegate()
        let latestURL = URL(string: "https://example.com/releases/latest")!
        XCTAssertTrue(widget.parseReleaseTagFromResolvedURL(latestURL) == nil)
    }

    func testParseReleaseTagFromLatestPointerUnderstandsRedirectStyle() {
        let widget = AppDelegate()
        let base = URL(fileURLWithPath: "/tmp/release-fixtures/releases", isDirectory: true)
        XCTAssertTrue(
            widget.parseReleaseTagFromLatestPointer(
                "/releases/tag/v3.2.1",
                releasesBaseURL: base
            ) == "v3.2.1"
        )
        XCTAssertTrue(
            widget.parseReleaseTagFromLatestPointer(
                "v3.2.1",
                releasesBaseURL: base
            ) == "v3.2.1"
        )
    }

    func testReleaseArchiveURLUsesDownloadTagPathForLocalAndRemote() {
        let widget = AppDelegate()
        let archiveName = "widget-server-v3.2.1-darwin-arm64.tar.gz"
        let remoteBase = URL(string: "https://example.com/releases")!
        let localBase = URL(fileURLWithPath: "/tmp/release-fixtures/releases", isDirectory: true)

        let remote = widget.releaseArchiveURL(
            releasesBaseURL: remoteBase,
            version: "v3.2.1",
            archiveName: archiveName
        )
        let local = widget.releaseArchiveURL(
            releasesBaseURL: localBase,
            version: "v3.2.1",
            archiveName: archiveName
        )

        XCTAssertTrue(remote.absoluteString.hasSuffix("/releases/download/v3.2.1/\(archiveName)"))
        XCTAssertTrue(local.path.hasSuffix("/releases/download/v3.2.1/\(archiveName)"))
    }

    func testReadLatestReleaseTagFromMockSourceReadsPointerFile() throws {
        let widget = AppDelegate()
        let fm = FileManager.default
        let releasesDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lolabunny-mock-releases-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: releasesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: releasesDir) }

        let latestPointer = releasesDir.appendingPathComponent("latest")
        try "/releases/tag/v4.5.6\n".write(to: latestPointer, atomically: true, encoding: .utf8)

        XCTAssertTrue(widget.readLatestReleaseTagFromMockSource(releasesURL: releasesDir) == "v4.5.6")
    }

    func testVersionComparisonUnderstandsSemver() {
        let widget = AppDelegate()

        XCTAssertTrue(widget.compareVersions("v1.2.10", "v1.2.9") == .orderedDescending)
        XCTAssertTrue(widget.compareVersions("v1.2.9", "v1.2.10") == .orderedAscending)
        XCTAssertTrue(widget.compareVersions("v1.2.9", "1.2.9") == .orderedSame)
        XCTAssertTrue(widget.compareVersions("v1.1-beta+1", "v1.0.1-beta+10") == .orderedDescending)
        XCTAssertTrue(widget.compareVersions("v1.2", "v1.2.0-beta+99") == .orderedSame)
        XCTAssertTrue(widget.parseSemVer("v1.7-beta+99") == SemVer(major: 1, minor: 7, patch: 0))
        XCTAssertTrue(widget.parseSemVer("invalid") == nil)
    }

    func testLatestCompatibleUpdateVersionOnlyReturnsNewerVersion() {
        let widget = AppDelegate()
        let candidates = [" v1.2.1 \n", "v1.2.0", "v1.1.9"]

        XCTAssertTrue(
            widget.latestCompatibleUpdateVersion(
                currentVersion: "v1.2.0",
                latestVersions: candidates
            ) == "v1.2.1"
        )
        XCTAssertTrue(
            widget.latestCompatibleUpdateVersion(
                currentVersion: "v1.2.1",
                latestVersions: candidates
            ) == nil
        )
        XCTAssertTrue(
            widget.latestCompatibleUpdateVersion(
                currentVersion: "v1.2.2",
                latestVersions: candidates
            ) == nil
        )
    }

    func testUpdateMenuVersionTextLooksReadable() {
        let widget = AppDelegate()
        XCTAssertTrue(
            widget.updateMenuVersionText(updateVersion: "v1.2.1") ==
                "Update Now v1.2.1"
        )
    }

    func testUpdateMenuVersionTextCompactsSuffixes() {
        let widget = AppDelegate()
        XCTAssertTrue(
            widget.updateMenuVersionText(updateVersion: "v1.1-beta+1") ==
                "Update Now v1.1"
        )
    }

    func testVersionMatchAllowsUnknownRequiredMajor() {
        let widget = AppDelegate()
        XCTAssertTrue(widget.versionMatchesRequiredMajor("v0.5.2", requiredMajor: ""))
        XCTAssertTrue(widget.versionMatchesRequiredMajor("v2.1.0", requiredMajor: " "))
        XCTAssertTrue(widget.versionMatchesRequiredMajor("v0.5.2-beta+1", requiredMajor: "alpha"))
    }

    func testBootstrapPermissionMessageWithoutMajorIsReadable() {
        XCTAssertTrue(
            Config.Notification.serverBootstrapPermissionMessage(requiredMajor: "") ==
                "Download compatible widget-server now?"
        )
    }

    func testStartupLaunchFailureIsClassifiedAsStartFailure() {
        let widget = AppDelegate()
        XCTAssertTrue(widget.isServerStartFailure("launch failed"))
        XCTAssertTrue(widget.isServerStartFailure("start failed"))
        XCTAssertTrue(widget.isServerStartFailure("Server failed to start"))
        XCTAssertTrue(!widget.isServerStartFailure("download failed"))
    }

    func testDownloadServerNowImmediatelyShowsProgressState() {
        let widget = AppDelegate()
        widget.serverSetupState = .WaitForDownloadPermission(requiredMajor: "1")

        widget.downloadServerNow()

        guard case .DownloadInflight(let phase, let progress) = widget.serverSetupState else {
            XCTFail("Expected .downloading state immediately after clicking download.")
            return
        }
        XCTAssertTrue(phase == "Preparing")
        XCTAssertTrue(progress > 0.0)
    }

    func testParseExpectedSHA256ExtractsArchiveHash() {
        let archive = "widget-server-v1.2.3-darwin-universal.tar.gz"
        let hash = String(repeating: "a", count: 64)
        let contents = "\(hash) *\(archive)\n"

        XCTAssertTrue(
            ServerArchiveUtils.parseExpectedSHA256(
                contents: contents,
                archiveName: archive
            ) == hash
        )
    }

    func testArchiveEntryOutputURLRejectsTraversal() {
        let baseDir = URL(fileURLWithPath: "/tmp/lolabunny-tests", isDirectory: true)

        let safe = ServerArchiveUtils.archiveEntryOutputURL(
            baseDir: baseDir,
            entryName: "./bin/widget-server"
        )
        XCTAssertTrue(safe?.path == baseDir.appendingPathComponent("bin/widget-server").path)

        let blocked = ServerArchiveUtils.archiveEntryOutputURL(
            baseDir: baseDir,
            entryName: "../etc/passwd"
        )
        XCTAssertTrue(blocked == nil)
    }

    func testServerBinaryLayoutIsFlatByVersion() {
        let widget = AppDelegate()
        let binary = widget.serverBinary(for: "v1.2.3")
        let locked = widget.lockedServerBinary(for: "v1.2.3")

        XCTAssertTrue(binary.lastPathComponent == Config.serverExecutableName)
        XCTAssertTrue(binary.deletingLastPathComponent().lastPathComponent == "v1.2.3")
        XCTAssertTrue(locked.deletingLastPathComponent().lastPathComponent == "v1.2.3.locked")
    }

    func testUnlockedVersionNameParsesLockedEntries() {
        let widget = AppDelegate()
        XCTAssertTrue(widget.unlockedVersionName(fromLockedEntry: "v1.2.3.locked") == "v1.2.3")
        XCTAssertTrue(widget.unlockedVersionName(fromLockedEntry: "v1.2.3") == nil)
        XCTAssertTrue(widget.unlockedVersionName(fromLockedEntry: ".locked") == nil)
    }
}
