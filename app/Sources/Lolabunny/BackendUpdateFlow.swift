import Foundation

extension AppDelegate {
    func isBackendArchiveAsset(_ name: String) -> Bool {
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
        let archives = release.assets.filter { isBackendArchiveAsset($0.name) }
        guard !archives.isEmpty else {
            log("latest release \(release.version) has no macOS backend archives")
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
            log(
                "no matching backend archive for architecture \(architectureAliases()) in release \(release.version)"
            )
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

    func latestCompatibleUpdateVersion(currentVersion: String, latestVersions: [String]) -> String? {
        let current = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = latestVersions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { compareVersions($0, $1) == .orderedDescending }

        guard !current.isEmpty else {
            return candidates.first
        }

        for candidate in candidates {
            if compareVersions(candidate, current) == .orderedDescending {
                return candidate
            }
        }
        return nil
    }

    func availableBackendUpdateVersion(currentVersion: String) -> String? {
        let requiredMajor = requiredBackendMajor()
        var candidates = Set(
            installedCompatibleVersions(requiredMajor: requiredMajor)
                + downloadedCompatibleVersions(requiredMajor: requiredMajor)
        )
        if let notified = updateState.lastNotifiedBackendVersion {
            candidates.insert(notified)
        }
        return latestCompatibleUpdateVersion(
            currentVersion: currentVersion,
            latestVersions: Array(candidates)
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
        return (now.timeIntervalSince1970 - last) >= Config.Backend.autoCheckInterval
    }

    func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: Config.Backend.schedulerTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runUpdateCheck(force: false, notify: false)
            }
        }
    }

    func runUpdateCheck(force: Bool, notify: Bool) {
        guard !isApplyingBackendUpdate else {
            return
        }
        guard shouldRunUpdateCheck(force: force) else {
            return
        }
        guard !isCheckingUpdates else {
            return
        }
        isCheckingUpdates = true

        let previousBackendNotified = updateState.lastNotifiedBackendVersion

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let outcome = await self.performUpdateCheck()
            self.applyUpdateCheckOutcome(
                outcome,
                notify: notify,
                previousBackendNotified: previousBackendNotified
            )
        }
    }

    func performUpdateCheck() async -> UpdateCheckOutcome {
        let now = Date().timeIntervalSince1970
        let requiredMajor = requiredBackendMajor()

        var backendCurrent = currentCompatibleBackendVersion()
        if let configured = configuredBackendVersion(),
            versionMatchesRequiredMajor(configured, requiredMajor: requiredMajor)
        {
            backendCurrent = configured
        } else if let running = await probeRunningBackendAsync() {
            backendCurrent = running
        }

        guard let latestRelease = await fetchLatestRelease() else {
            return UpdateCheckOutcome(
                checkedAt: now,
                backendLatestAvailable: nil,
                error: "failed to check latest release"
            )
        }

        let latest = latestRelease.version.trimmingCharacters(in: .whitespacesAndNewlines)
        var backendLatest: String?
        var checkError: String?

        if versionMatchesRequiredMajor(latest, requiredMajor: requiredMajor),
            compareVersions(latest, backendCurrent) == .orderedDescending
        {
            let hasRunnableLocalBackend = resolveLaunchTarget() != nil
            if let selection = selectReleaseAssets(from: latestRelease) {
                let installedBinary = backendBinary(for: latest)
                let lockedBinary = lockedBackendBinary(for: latest)
                if canLaunchBackendBinary(installedBinary) || canLaunchBackendBinary(lockedBinary) {
                    backendLatest = latest
                } else if !hasRunnableLocalBackend {
                    log("auto-download skipped: no runnable local backend, user permission required")
                } else if !allowAutomaticBackendDownloads {
                    log("auto-download skipped: waiting for bootstrap permission")
                } else if await downloadAndStageBackend(selection: selection) != nil {
                    backendLatest = latest
                } else {
                    checkError = "failed to download backend \(latest)"
                }
            }
        }

        return UpdateCheckOutcome(
            checkedAt: now,
            backendLatestAvailable: backendLatest,
            error: checkError
        )
    }

    func applyUpdateCheckOutcome(
        _ outcome: UpdateCheckOutcome,
        notify: Bool,
        previousBackendNotified: String?
    ) {
        isCheckingUpdates = false
        updateState.lastCheckedAt = outcome.checkedAt

        if outcome.error != nil {
            if notify {
                postNotification(
                    title: Config.displayName,
                    body: Config.Notification.updatesCheckFailedMessage
                )
            }
            return
        }

        var backendUpdateToNotify: String?
        if let backendLatest = outcome.backendLatestAvailable {
            let shouldNotify = notify || backendLatest != previousBackendNotified
            if shouldNotify {
                backendUpdateToNotify = backendLatest
                updateState.lastNotifiedBackendVersion = backendLatest
            }
        } else {
            updateState.lastNotifiedBackendVersion = nil
        }

        if let backendVersion = backendUpdateToNotify {
            postBackendUpdateReadyNotification(backendVersion)
        } else if notify {
            postNotification(title: Config.displayName, body: Config.Notification.noUpdatesMessage)
        }
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        guard let downloader = makeConfiguredGistBackendDownloader(requireManifest: true) else {
            return nil
        }
        return await downloader.fetchLatestRelease()
    }

    nonisolated func downloadFileWithBackendDownloader(
        from sourceURL: URL,
        assetName: String,
        to destinationURL: URL,
        expectedSHA256Hex: String? = nil,
        progress: (@MainActor (Double?) -> Void)? = nil
    ) async -> Bool {
        let fm = FileManager.default
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".download-\(UUID().uuidString).tmp")
        if fm.fileExists(atPath: tempURL.path) {
            try? fm.removeItem(at: tempURL)
        }
        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            log("download failed: could not create temp file \(tempURL.path)")
            return false
        }
        var shouldCleanupTempFile = true
        defer {
            if shouldCleanupTempFile {
                try? fm.removeItem(at: tempURL)
            }
        }

        let downloader: any BackendDownloader
        let request: DownloadBackendRequest
        if shouldUseGistDownloader(for: sourceURL),
            let gistDownloader = makeConfiguredGistBackendDownloader(requireManifest: false)
        {
            downloader = gistDownloader
            request = DownloadBackendRequest(
                version: assetName,
                expectedSHA256Hex: expectedSHA256Hex
            )
        } else {
            downloader = HttpBackendDownloader(
                baseURL: sourceURL.deletingLastPathComponent(),
                userAgent: Config.displayName
            )
            request = DownloadBackendRequest(
                version: assetName,
                expectedSHA256Hex: expectedSHA256Hex,
                sourceURL: sourceURL
            )
        }

        do {
            let response = try await downloader.download(request: request)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer {
                try? handle.close()
            }

            var chunkCount = 0
            if let progress {
                await progress(0.0)
            }

            for try await chunk in response.chunks {
                if !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                }
                chunkCount += 1

                if let progress {
                    // HTTP chunks do not expose expected total size; use a smooth bounded estimate.
                    let synthetic = min(0.95, Double(chunkCount) * 0.03)
                    await progress(synthetic)
                }

                if Config.Backend.downloadChunkDelayMillis > 0 {
                    try await Task.sleep(
                        nanoseconds: Config.Backend.downloadChunkDelayMillis * 1_000_000
                    )
                }
            }

            try handle.synchronize()
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: tempURL, to: destinationURL)

            if let progress {
                await progress(1.0)
            }

            shouldCleanupTempFile = false
            return true
        } catch {
            log("download failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private func shouldUseGistDownloader(for sourceURL: URL) -> Bool {
        guard Config.Backend.updateProvider?.caseInsensitiveCompare("GitHubGist") == .orderedSame else {
            return false
        }
        guard let host = sourceURL.host?.lowercased() else {
            return false
        }
        return host == "gist.githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    nonisolated private func makeConfiguredGistBackendDownloader(
        requireManifest: Bool
    ) -> GistBackendDownloader? {
        guard let provider = Config.Backend.updateProvider else {
            log("missing update provider config")
            return nil
        }
        guard provider.caseInsensitiveCompare("GitHubGist") == .orderedSame else {
            log("unsupported update provider: \(provider)")
            return nil
        }
        guard let gistID = Config.Backend.updateGitHubGistID else {
            log("missing GitHubGist update gist ID config")
            return nil
        }

        let manifest = Config.Backend.updateGitHubGistManifestFile
        if requireManifest, manifest == nil {
            log("missing GitHubGist update manifest file config")
            return nil
        }

        let downloader = GistBackendDownloader(
            gistID: gistID,
            manifestFileName: manifest,
            userAgent: Config.displayName
        )
        if downloader == nil, let manifest {
            log("invalid GitHubGist update config: gistID=\(gistID), manifest=\(manifest)")
        } else if downloader == nil {
            log("invalid GitHubGist update config: gistID=\(gistID)")
        }
        return downloader
    }
}
