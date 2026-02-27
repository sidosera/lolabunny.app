import Cocoa
import CryptoKit
import SWCompression

extension AppDelegate {
    func isServerArchiveAsset(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains(Config.appName)
            && (n.contains("darwin") || n.contains("macos"))
            && n.hasSuffix(".tar.gz")
            && !n.hasSuffix(".tar.gz.sha256")
    }

    func matchesArch(_ assetName: String, archToken: String) -> Bool {
        let n = assetName.lowercased()
        let t = archToken.lowercased()
        return n.contains("-\(t).") || n.contains("-\(t)-") || n.hasSuffix("\(t).tar.gz")
    }

    func selectReleaseAssets(from release: ReleaseInfo) -> ReleaseAssetSelection? {
        let archives = release.assets.filter { isServerArchiveAsset($0.name) }
        guard !archives.isEmpty else {
            log("latest release \(release.version) has no macOS server archives")
            return nil
        }

        let aliases = architectureAliases()
        var selectedArchive: ReleaseAsset?
        for alias in aliases {
            if let match = archives.first(where: { matchesArch($0.name, archToken: alias) }) {
                selectedArchive = match
                break
            }
        }
        if selectedArchive == nil,
           let universal = archives.first(where: { $0.name.lowercased().contains("universal") })
        {
            selectedArchive = universal
        }
        if selectedArchive == nil, archives.count == 1 {
            selectedArchive = archives[0]
        }
        guard let archive = selectedArchive else {
            log("no matching server archive for architecture \(architectureAliases()) in release \(release.version)")
            return nil
        }

        let checksumName = archive.name + ".sha256"
        let checksum = release.assets.first { $0.name == checksumName }
        guard let checksum else {
            log("checksum asset missing for archive \(archive.name)")
            return nil
        }

        return ReleaseAssetSelection(
            version: release.version.trimmingCharacters(in: .whitespacesAndNewlines),
            archive: archive,
            checksum: checksum
        )
    }

    func shouldRunUpdateCheck(force: Bool, now: Date = Date()) -> Bool {
        if force {
            return true
        }
        if shouldSkipAutomaticUpdateChecks() {
            return false
        }
        guard let last = updateState.lastCheckedAt else {
            return true
        }
        return (now.timeIntervalSince1970 - last) >= Config.Server.autoCheckInterval
    }

    func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: Config.Server.schedulerTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runUpdateCheck(force: false, notify: false)
            }
        }
    }

    func runUpdateCheck(force: Bool, notify: Bool) {
        guard !isApplyingServerUpdate else {
            return
        }
        guard shouldRunUpdateCheck(force: force) else {
            return
        }
        guard !isCheckingUpdates else {
            return
        }
        isCheckingUpdates = true

        let previousServerNotified = updateState.lastNotifiedServerVersion

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performUpdateCheck()
            self.applyUpdateCheckOutcome(
                outcome,
                notify: notify,
                previousServerNotified: previousServerNotified
            )
        }
    }

    func performUpdateCheck() async -> UpdateCheckOutcome {
        let now = Date().timeIntervalSince1970
        let bundled = bundledVersion()
        let requiredMajor = majorVersion(bundled)
        let serverCurrent = await probeRunningServerAsync() ?? currentCompatibleServerVersion()

        guard let latestRelease = await fetchLatestRelease() else {
            return UpdateCheckOutcome(
                checkedAt: now,
                serverLatestAvailable: nil,
                error: "failed to check latest release"
            )
        }

        let latest = latestRelease.version.trimmingCharacters(in: .whitespacesAndNewlines)

        var serverLatest: String?
        var checkError: String?
        if majorVersion(latest) == requiredMajor,
           compareVersions(latest, serverCurrent) == .orderedDescending
        {
            if let selection = selectReleaseAssets(from: latestRelease) {
                let installedBinary = managedServerBinary(for: latest)
                let pendingBinary = pendingServerBinary(for: latest)
                if canLaunchServerBinary(installedBinary) || canLaunchServerBinary(pendingBinary) {
                    serverLatest = latest
                } else if await downloadAndStageServer(selection: selection) != nil {
                    serverLatest = latest
                } else {
                    checkError = "failed to download server \(latest)"
                }
            }
        }

        return UpdateCheckOutcome(
            checkedAt: now,
            serverLatestAvailable: serverLatest,
            error: checkError
        )
    }

    func applyUpdateCheckOutcome(
        _ outcome: UpdateCheckOutcome,
        notify: Bool,
        previousServerNotified: String?
    ) {
        isCheckingUpdates = false

        updateState.lastCheckedAt = outcome.checkedAt

        if outcome.error != nil {
            if notify {
                postNotification(title: Config.displayName, body: Config.Notification.updatesCheckFailedMessage)
            }
            return
        }

        var serverUpdateToNotify: String?
        if let serverLatest = outcome.serverLatestAvailable {
            let shouldNotifyServer = notify || serverLatest != previousServerNotified
            if shouldNotifyServer {
                serverUpdateToNotify = serverLatest
                updateState.lastNotifiedServerVersion = serverLatest
            }
        } else {
            updateState.lastNotifiedServerVersion = nil
        }

        if let serverVersion = serverUpdateToNotify {
            postUpdateReadyNotification(serverVersion)
        } else if notify {
            postNotification(title: Config.displayName, body: Config.Notification.noUpdatesMessage)
        }
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        await updateSource.fetchLatestRelease()
    }

    func downloadFile(from sourceURL: URL, to destinationURL: URL) async -> Bool {
        var req = URLRequest(url: sourceURL)
        req.timeoutInterval = 120
        req.setValue(Config.displayName, forHTTPHeaderField: "User-Agent")

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: req)
            guard let http = response as? HTTPURLResponse else {
                log("download failed: missing HTTP response")
                return false
            }
            guard (200 ... 299).contains(http.statusCode) else {
                log("download failed: status=\(http.statusCode)")
                return false
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: tempURL, to: destinationURL)
            return true
        } catch {
            log("download failed: \(error.localizedDescription)")
            return false
        }
    }

    func sha256Hex(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            log("failed to read \(fileURL.path) for sha256")
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func parseExpectedSHA256(contents: String, archiveName: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else {
                continue
            }
            let hash = String(first).lowercased()
            guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                continue
            }
            if fields.count == 1 {
                return hash
            }
            let fileField = fields.dropFirst().map(String.init).joined(separator: " ")
            let normalized = fileField
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "*", with: "")
            if normalized.hasSuffix(archiveName) {
                return hash
            }
        }
        return nil
    }

    func verifyDownloadedArchive(archiveURL: URL, checksumURL: URL, archiveName: String) -> Bool {
        guard let checksumContents = try? String(contentsOf: checksumURL, encoding: .utf8) else {
            log("failed reading checksum file \(checksumURL.path)")
            return false
        }
        guard let expected = parseExpectedSHA256(contents: checksumContents, archiveName: archiveName) else {
            log("checksum file did not include a valid hash for \(archiveName)")
            return false
        }
        guard let actual = sha256Hex(for: archiveURL) else {
            return false
        }
        guard expected == actual else {
            log("checksum mismatch for \(archiveName): expected \(expected), got \(actual)")
            return false
        }
        return true
    }

    func archiveEntryOutputURL(baseDir: URL, entryName: String) -> URL? {
        var relativePath = entryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if relativePath.isEmpty {
            return nil
        }
        while relativePath.hasPrefix("./") {
            relativePath.removeFirst(2)
        }
        while relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        if relativePath.isEmpty {
            return nil
        }

        var outputURL = baseDir
        for component in relativePath.split(separator: "/") {
            let part = String(component)
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." {
                return nil
            }
            outputURL.appendPathComponent(part, isDirectory: false)
        }

        let basePath = baseDir.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        if outputPath == basePath || outputPath.hasPrefix(basePath + "/") {
            return outputURL
        }
        return nil
    }

    func extractArchive(_ archiveURL: URL, to destinationDir: URL) -> Bool {
        let fm = FileManager.default
        do {
            let compressedData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
            let tarData = try GzipArchive.unarchive(archive: compressedData)
            let entries = try TarContainer.open(container: tarData)

            for entry in entries {
                guard let outputURL = archiveEntryOutputURL(baseDir: destinationDir, entryName: entry.info.name) else {
                    log("failed to extract archive: unsafe entry path \(entry.info.name)")
                    return false
                }

                switch entry.info.type {
                case .directory:
                    try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
                case .regular, .contiguous:
                    guard let data = entry.data else {
                        log("failed to extract archive: missing file data for \(entry.info.name)")
                        return false
                    }
                    try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: outputURL, options: .atomic)
                    if let permissions = entry.info.permissions {
                        try fm.setAttributes([.posixPermissions: Int(permissions.rawValue)], ofItemAtPath: outputURL.path)
                    }
                default:
                    log("failed to extract archive: unsupported entry type \(entry.info.type) for \(entry.info.name)")
                    return false
                }
            }
            return true
        } catch {
            log("failed to extract archive: \(error.localizedDescription)")
            return false
        }
    }

    func downloadAndStageServer(selection: ReleaseAssetSelection) async -> URL? {
        let fm = FileManager.default
        let version = selection.version
        let targetBinary = pendingServerBinary(for: version)
        if fm.isExecutableFile(atPath: targetBinary.path), canLaunchServerBinary(targetBinary) {
            return targetBinary
        }
        let archiveRemoteURL = selection.archive.downloadURL
        let checksumAsset = selection.checksum
        let checksumRemoteURL = checksumAsset.downloadURL

        guard ensureDirectory(pendingServerRoot) else {
            return nil
        }

        let stagingRoot = pendingServerRoot
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            log("failed to create staging directory: \(error.localizedDescription)")
            return nil
        }
        defer { try? fm.removeItem(at: stagingRoot) }

        let archiveURL = stagingRoot.appendingPathComponent(selection.archive.name)
        let checksumURL = stagingRoot.appendingPathComponent(checksumAsset.name)

        log("downloading server \(version) asset \(selection.archive.name)")
        guard await downloadFile(from: archiveRemoteURL, to: archiveURL) else {
            return nil
        }
        guard await downloadFile(from: checksumRemoteURL, to: checksumURL) else {
            return nil
        }
        guard verifyDownloadedArchive(
            archiveURL: archiveURL,
            checksumURL: checksumURL,
            archiveName: selection.archive.name
        ) else {
            return nil
        }

        let extractedDir = stagingRoot.appendingPathComponent("extract", isDirectory: true)
        do {
            try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        } catch {
            log("failed to create extraction directory: \(error.localizedDescription)")
            return nil
        }
        guard extractArchive(archiveURL, to: extractedDir) else {
            return nil
        }

        let extractedBinary = extractedDir.appendingPathComponent(Config.appName)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)
        } catch {
            log("failed to set executable permissions: \(error.localizedDescription)")
        }
        guard canLaunchServerBinary(extractedBinary) else {
            log("downloaded server binary is not runnable for current architecture")
            return nil
        }

        let finalArchDir = targetBinary.deletingLastPathComponent()
        let finalVersionDir = finalArchDir.deletingLastPathComponent()
        guard ensureDirectory(finalVersionDir) else {
            return nil
        }
        if fm.fileExists(atPath: finalArchDir.path) {
            try? fm.removeItem(at: finalArchDir)
        }
        do {
            try fm.moveItem(at: extractedDir, to: finalArchDir)
        } catch {
            log("failed to stage server \(version): \(error.localizedDescription)")
            return nil
        }

        let finalBinary = finalArchDir.appendingPathComponent(Config.appName)
        guard canLaunchServerBinary(finalBinary) else {
            try? fm.removeItem(at: finalArchDir)
            log("staged server \(version) failed post-install validation")
            return nil
        }
        log("staged server \(version) at \(finalBinary.path)")
        return finalBinary
    }

    func promotePendingServer(version: String) -> Bool {
        let fm = FileManager.default
        let activeArchDir = managedServerBinary(for: version).deletingLastPathComponent()
        let activeBinary = activeArchDir.appendingPathComponent(Config.appName)
        if fm.isExecutableFile(atPath: activeBinary.path), canLaunchServerBinary(activeBinary) {
            return true
        }

        let pendingArchDir = pendingServerBinary(for: version).deletingLastPathComponent()
        guard fm.fileExists(atPath: pendingArchDir.path) else {
            log("no staged server update found for \(version)")
            return false
        }

        let activeVersionDir = activeArchDir.deletingLastPathComponent()
        guard ensureDirectory(activeVersionDir) else {
            return false
        }
        if fm.fileExists(atPath: activeArchDir.path) {
            try? fm.removeItem(at: activeArchDir)
        }
        do {
            try fm.moveItem(at: pendingArchDir, to: activeArchDir)
        } catch {
            log("failed to activate staged server \(version): \(error.localizedDescription)")
            return false
        }

        guard canLaunchServerBinary(activeBinary) else {
            try? fm.removeItem(at: activeArchDir)
            log("activated server \(version) failed validation")
            return false
        }
        return true
    }

    func removeInstalledServer(version: String) {
        let fm = FileManager.default
        let archDir = managedServerBinary(for: version).deletingLastPathComponent()
        if fm.fileExists(atPath: archDir.path) {
            try? fm.removeItem(at: archDir)
        }
        let versionDir = archDir.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(atPath: versionDir.path), entries.isEmpty {
            try? fm.removeItem(at: versionDir)
        }
    }

    func removePendingServer(version: String) {
        let fm = FileManager.default
        let archDir = pendingServerBinary(for: version).deletingLastPathComponent()
        if fm.fileExists(atPath: archDir.path) {
            try? fm.removeItem(at: archDir)
        }
        let versionDir = archDir.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(atPath: versionDir.path), entries.isEmpty {
            try? fm.removeItem(at: versionDir)
        }
    }

    func waitForServerVersion(_ version: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeRunningServerAsync() == version {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func applyDownloadedServerUpdate(version: String) {
        guard !isApplyingServerUpdate else {
            log("server apply already in progress")
            return
        }
        isApplyingServerUpdate = true
        log("applying staged server update \(version)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            let previous = await self.probeRunningServerAsync() ?? self.currentCompatibleServerVersion()

            guard self.promotePendingServer(version: version) else {
                self.isApplyingServerUpdate = false
                self.postNotification(title: Config.displayName, body: Config.Notification.serverUpdateApplyFailedMessage)
                return
            }

            self.stopRunningServer()
            await self.startServer()
            let applied = await self.waitForServerVersion(version, timeout: 8)

            if !applied {
                self.removeInstalledServer(version: version)
                self.stopRunningServer()
                await self.startServer()
                _ = await self.waitForServerVersion(previous, timeout: 8)
            } else {
                self.removePendingServer(version: version)
            }

            self.isApplyingServerUpdate = false
            if applied {
                self.updateState.lastNotifiedServerVersion = nil
                self.postNotification(title: Config.displayName, body: Config.Notification.serverUpdatedMessage(version))
            } else {
                self.postNotification(title: Config.displayName, body: Config.Notification.serverUpdateApplyFailedMessage)
            }
            self.runUpdateCheck(force: true, notify: false)
        }
    }
}
