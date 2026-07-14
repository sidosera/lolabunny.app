import Foundation

extension AppDelegate {
    nonisolated func isServerUpdateSourceConfigured() -> Bool {
        Config.Server.updateReleasesURL != nil
    }

    nonisolated func configuredPinnedUpdateVersion() -> String? {
        if let explicit = Config.Server.updateReleaseTag {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.caseInsensitiveCompare("latest") != .orderedSame {
                return trimmed
            }
        }
        return nil
    }

    func canonicalServerArchiveName(version: String) -> String {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedArch = architectureAliases().first ?? architectureLabel().lowercased()
        let arch = detectedArch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "lolabunny-server@\(trimmedVersion)-darwin-\(arch).tar.gz"
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

    func availableServerUpdateVersion(currentVersion: String) -> String? {
        let requiredMajor = requiredServerMajor()
        var candidates = Set(
            installedCompatibleVersions(requiredMajor: requiredMajor)
                + downloadedCompatibleVersions(requiredMajor: requiredMajor)
        )
        if let notified = updateState.lastNotifiedServerVersion {
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
        return (now.timeIntervalSince1970 - last) >= Config.Server.autoCheckInterval
    }

    func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: Config.Server.schedulerTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runUpdateCheck(force: false, notify: false)
            }
        }
    }

    func runUpdateCheck(force: Bool, notify: Bool) {
        guard isServerUpdateSourceConfigured() else {
            return
        }
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
            guard let self else {
                return
            }
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
        let requiredMajor = requiredServerMajor()

        var serverCurrent = currentCompatibleServerVersion()
        if let configured = configuredServerVersion(),
            versionMatchesRequiredMajor(configured, requiredMajor: requiredMajor)
        {
            serverCurrent = configured
        } else if let running = await probeRunningServerAsync() {
            serverCurrent = running
        }

        guard let latestRelease = await fetchLatestRelease() else {
            return UpdateCheckOutcome(
                checkedAt: now,
                serverLatestAvailable: nil,
                error: "failed to check latest release"
            )
        }

        let latest = latestRelease.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let rollingLatestMode = latest.caseInsensitiveCompare("latest") == .orderedSame

        if rollingLatestMode {
            return UpdateCheckOutcome(
                checkedAt: now,
                serverLatestAvailable: nil,
                error: nil
            )
        }

        guard versionMatchesRequiredMajor(latest, requiredMajor: requiredMajor),
              compareVersions(latest, serverCurrent) == .orderedDescending
        else {
            return UpdateCheckOutcome(
                checkedAt: now,
                serverLatestAvailable: nil,
                error: nil
            )
        }

        log("update available: \(latest) (current: \(serverCurrent))")
        return UpdateCheckOutcome(
            checkedAt: now,
            serverLatestAvailable: latest,
            error: nil
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
                postNotification(
                    title: Config.displayName,
                    body: Config.Notification.updatesCheckFailedMessage
                )
            }
            return
        }

        var serverUpdateToNotify: String?
        if let serverLatest = outcome.serverLatestAvailable {
            let shouldNotify = notify || serverLatest != previousServerNotified
            if shouldNotify {
                serverUpdateToNotify = serverLatest
                updateState.lastNotifiedServerVersion = serverLatest
            }
        } else {
            updateState.lastNotifiedServerVersion = nil
        }

        if let serverVersion = serverUpdateToNotify {
            postServerUpdateReadyNotification(serverVersion)
        } else if notify {
            postNotification(title: Config.displayName, body: Config.Notification.noUpdatesMessage)
        }
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        guard let releasesBaseURL = Config.Server.updateReleasesURL else {
            log("missing update releases URL config")
            return nil
        }

        let version: String
        if let pinned = configuredPinnedUpdateVersion() {
            version = pinned
        } else {
            guard let latest = await fetchLatestReleaseTag(
                releasesURL: releasesBaseURL
            )
            else {
                return nil
            }
            version = latest
        }

        let archiveName = canonicalServerArchiveName(version: version)
        let archiveURL = releaseArchiveURL(
            releasesBaseURL: releasesBaseURL,
            version: version,
            archiveName: archiveName
        )
        return ReleaseInfo(version: version, archiveURL: archiveURL)
    }

    nonisolated func releaseArchiveURL(
        releasesBaseURL: URL,
        version: String,
        archiveName: String
    ) -> URL {
        releasesBaseURL
            .appendingPathComponent("download")
            .appendingPathComponent(version)
            .appendingPathComponent(archiveName)
    }

    nonisolated func parseReleaseTagFromResolvedURL(_ resolvedURL: URL) -> String? {
        let marker = "/releases/tag/"
        guard let markerRange = resolvedURL.path.range(of: marker) else {
            return nil
        }
        var tag = String(resolvedURL.path[markerRange.upperBound...])
        if let slash = tag.firstIndex(of: "/") {
            tag = String(tag[..<slash])
        }
        let trimmed = (tag.removingPercentEncoding ?? tag)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func fetchLatestReleaseTag(releasesURL: URL) async -> String? {
        if releasesURL.isFileURL {
            return readLatestReleaseTagFromMockSource(releasesURL: releasesURL)
        }

        let latestURL = releasesURL.appendingPathComponent("latest")
        var request = URLRequest(url: latestURL)
        request.timeoutInterval = 10
        request.setValue(Config.displayName, forHTTPHeaderField: "User-Agent")

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            log("failed to resolve latest release at \(latestURL.absoluteString): \(error.localizedDescription)")
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            log("latest release request failed (\(http.statusCode)) for \(latestURL.absoluteString)")
            return nil
        }

        guard let finalURL = response.url else {
            log("latest release request returned no resolved URL")
            return nil
        }

        guard let tag = parseReleaseTagFromResolvedURL(finalURL) else {
            log("failed to parse release tag from URL \(finalURL.absoluteString)")
            return nil
        }
        return tag
    }

    nonisolated func parseReleaseTagFromLatestPointer(
        _ rawValue: String,
        releasesBaseURL: URL
    ) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return parseReleaseTagFromResolvedURL(absolute) ?? trimmed
        }

        if let resolved = URL(string: trimmed, relativeTo: releasesBaseURL)?.absoluteURL,
            let parsed = parseReleaseTagFromResolvedURL(resolved)
        {
            return parsed
        }

        return trimmed
    }

    func readLatestReleaseTagFromMockSource(releasesURL: URL) -> String? {
        let pointerURL = releasesURL.appendingPathComponent("latest")
        guard
            let contents = try? String(contentsOf: pointerURL, encoding: .utf8),
            let tag = parseReleaseTagFromLatestPointer(contents, releasesBaseURL: releasesURL)
        else {
            log("failed to read mocked latest release pointer at \(pointerURL.path)")
            return nil
        }
        return tag
    }

    nonisolated func downloadFileWithServerDownloader(
        from sourceURL: URL,
        to destinationURL: URL,
        downloader: any ServerDownloader,
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

        let stream: AsyncThrowingStream<Data, Error>
        do {
            stream = try await downloader.download(from: sourceURL)
        } catch {
            log("download failed: \(error.localizedDescription)")
            return false
        }

        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            defer {
                try? handle.close()
            }

            var chunkCount = 0
            if let progress {
                await progress(0.0)
            }

            for try await chunk in stream {
                if !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                }
                chunkCount += 1

                if let progress {
                    // Stream chunks do not expose expected total size; use a smooth bounded estimate.
                    let synthetic = min(0.95, Double(chunkCount) * 0.03)
                    await progress(synthetic)
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

    nonisolated func makeServerDownloader(for sourceURL: URL) -> any ServerDownloader {
        if sourceURL.isFileURL {
            return makeLocalhostServerDownloader()
        }
        return HttpServerDownloader(userAgent: Config.displayName)
    }

    nonisolated private func makeLocalhostServerDownloader() -> LocalhostServerDownloader {
        LocalhostServerDownloader(
            streamDelayMillis: Config.Server.updateLocalStreamDelayMillis
        )
    }
}
