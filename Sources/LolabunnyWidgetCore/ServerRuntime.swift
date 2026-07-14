import Foundation

extension AppDelegate {
    func scheduleServerWatchdog() {
        serverWatchdogTimer?.invalidate()
        serverWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Config.Server.watchdogIntervalSeconds, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.serverWatchdogTick()
            }
        }
    }

    func serverWatchdogTick() async {
        if isApplyingServerUpdate || isBootstrappingServer || isStartingServer {
            return
        }
        switch serverSetupState {
        case .GettingReady, .WaitForDownloadPermission, .DownloadInflight:
            return
        case .Ready, .Failed:
            break
        }

        if await probeRunningServerAsync() != nil {
            return
        }

        if Config.Server.externallyManaged {
            log("watchdog: externally managed widget-server is not healthy")
            setServerSetupState(.Failed(message: "external widget-server unavailable"))
            return
        }

        if let pid = readPidFile(), isProcessRunning(pid) {
            log("watchdog: widget-server pid=\(pid) is unresponsive, restarting")
            stopRunningServer()
        } else {
            log("watchdog: widget-server is not running, starting")
        }
        await startServer()
    }

    func startServer() async {
        await startManagedServer()
    }

    func startManagedServer() async {
        guard !isStartingServer else {
            return
        }
        isStartingServer = true
        defer { isStartingServer = false }

        let requiredMajor = requiredServerMajor()

        if Config.Server.externallyManaged {
            setServerSetupState(.GettingReady)
            if let version = await probeRunningServerAsync() {
                setServerSetupState(.Ready(version: version))
                log("using externally managed widget-server \(version) at \(Config.serverBaseURL.absoluteString)")
            } else {
                setServerSetupState(.Failed(message: "external widget-server unavailable"))
                log("externally managed widget-server unavailable at \(Config.serverBaseURL.absoluteString)")
            }
            return
        }

        let target = resolveLaunchTarget()
        guard let target else {
            lastServerLaunchAttemptVersion = nil
            requestBootstrapPermission(requiredMajor: requiredMajor)
            log("no widget-server binary available to launch")
            return
        }

        lastServerLaunchAttemptVersion = target.version
        setServerSetupState(.GettingReady)
        let desiredArgsSignature = serverLaunchArgsSignature()

        if let pid = readPidFile(), isProcessRunning(pid), await probeRunningServerAsync() != nil {
            if readRecordedServerLaunchArgsSignature() == desiredArgsSignature {
                setServerSetupState(.Ready(version: target.version))
                log("target widget-server already running (pid=\(pid), target=\(target.version))")
                return
            }
            log("running widget-server is healthy but has stale launch args, restarting")
            stopRunningServer()
        } else if let pid = readPidFile(), isProcessRunning(pid) {
            log("widget-server pid file exists but health check failed (pid=\(pid)), restarting")
            stopRunningServer()
        }

        guard launchServer(binary: target.binary, version: target.version) else {
            setServerSetupState(.Failed(message: "launch failed"))
            return
        }

        guard await waitForServerVersion(
            target.version,
            timeout: Config.Server.launchHealthTimeoutSeconds
        ) else {
            log("widget-server failed health check after launch, restarting required")
            stopRunningServer()
            setServerSetupState(.Failed(message: "start failed"))
            return
        }
        setServerSetupState(.Ready(version: target.version))
    }

    func requestBootstrapPermission(requiredMajor: String) {
        pendingBootstrapServerRequiredMajor = requiredMajor
        setServerSetupState(.WaitForDownloadPermission(requiredMajor: requiredMajor))
        guard !bootstrapPromptPosted else {
            return
        }
        bootstrapPromptPosted = true
        log("requesting user permission to download widget-server major \(requiredMajor)")
        postBootstrapPermissionNotification(requiredMajor: requiredMajor)
    }

    func beginBootstrapServerDownload(
        requiredMajor: String?,
        downloader: (any ServerDownloader)? = nil
    ) async {
        guard !isBootstrappingServer else {
            return
        }
        let major = requiredMajor ?? pendingBootstrapServerRequiredMajor ?? requiredServerMajor()
        isBootstrappingServer = true
        setServerSetupState(.DownloadInflight(phase: "Preparing", progress: 0.05))

        guard isServerUpdateSourceConfigured() else {
            isBootstrappingServer = false
            setServerSetupState(.Failed(message: "download unavailable: update source is not configured"))
            log("bootstrap download unavailable: update source is not configured")
            return
        }

        let target = await bootstrapServerFromDistribution(
            requiredMajor: major,
            downloader: downloader
        )
        isBootstrappingServer = false

        guard target != nil else {
            setServerSetupState(.Failed(message: "download failed"))
            postNotification(title: Config.displayName, body: Config.Notification.serverBootstrapFailedMessage)
            return
        }

        bootstrapPromptPosted = false
        pendingBootstrapServerRequiredMajor = nil
        await startServer()
    }

    func bootstrapServerFromDistribution(
        requiredMajor: String,
        downloader: (any ServerDownloader)? = nil
    ) async -> (binary: URL, version: String)? {
        setServerSetupState(.DownloadInflight(phase: "Checking latest release", progress: 0.10))
        guard let release = await fetchLatestRelease() else {
            log("bootstrap widget-server download skipped: latest release unavailable")
            return nil
        }
        let version = release.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let rollingLatestMode = version.caseInsensitiveCompare("latest") == .orderedSame
        if !rollingLatestMode,
            !versionMatchesRequiredMajor(version, requiredMajor: requiredMajor)
        {
            log("bootstrap widget-server version \(version) is not compatible with required major \(requiredMajor)")
            return nil
        }
        setServerSetupState(.DownloadInflight(phase: "Selecting artifacts", progress: 0.20))
        let selectedDownloader = downloader ?? makeServerDownloader(for: release.archiveURL)
        guard let staged = await downloadAndStageServer(
            version: version,
            archiveURL: release.archiveURL,
            downloader: selectedDownloader
        ) else {
            log("bootstrap widget-server download failed for \(version)")
            return nil
        }
        if !versionMatchesRequiredMajor(staged.version, requiredMajor: requiredMajor) {
            removeDownloadedLockedServer(version: staged.version)
            log("bootstrap widget-server version \(staged.version) is not compatible with required major \(requiredMajor)")
            return nil
        }
        setServerSetupState(.DownloadInflight(phase: "Activating widget-server", progress: 0.92))
        guard activateDownloadedServer(version: staged.version) else {
            log("bootstrap widget-server activation failed for \(staged.version)")
            return nil
        }
        let binary = serverBinary(for: staged.version)
        log("bootstrap widget-server installed \(staged.version) to \(binary.path)")
        setServerSetupState(.DownloadInflight(phase: "Finalizing", progress: 1.0))
        return (binary, staged.version)
    }

    func readPidFile() -> pid_t? {
        guard let contents = try? String(contentsOfFile: Config.Server.pidFile, encoding: .utf8) else {
            return nil
        }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    func stopRunningServer() {
        guard !Config.Server.externallyManaged else {
            return
        }
        if let proc = serverProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            serverProcess = nil
            log("stopped managed widget-server process")
            return
        }
        if let pid = readPidFile(), isProcessRunning(pid) {
            kill(pid, SIGTERM)
            log("sent SIGTERM to widget-server pid=\(pid)")
            usleep(500_000)
        }
    }

    func probeRunningServerAsync() async -> String? {
        let url = Config.serverBaseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func bundledVersion() -> String {
        Config.Server.version
    }

    func majorVersion(_ version: String) -> String {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return String(v.prefix(while: { $0 != "." }))
    }

    func serverLaunchArguments() -> [String] {
        var args = [
            "serve",
            "--port", "\(Config.serverPort)",
            "--address", Config.Server.address,
            "--log-level", Config.Server.logLevel,
            "--default-search", Config.Server.defaultSearch,
            "--history-enabled", Config.Server.historyEnabled ? "true" : "false",
            "--history-max-entries", "\(Config.Server.historyMaxEntries)"
        ]
        if let volumePath = Config.Server.volumePath {
            args += ["--volume-path", volumePath]
        }
        return args
    }

    func serverLaunchArgsSignature() -> String {
        serverLaunchArguments().joined(separator: "\n")
    }

    func readRecordedServerLaunchArgsSignature() -> String? {
        guard let value = try? String(contentsOfFile: Config.Server.launchArgsSignatureFile, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func writeRecordedServerLaunchArgsSignature(_ signature: String) {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Config.Server.runtimeDir, isDirectory: true),
                withIntermediateDirectories: true
            )
            try signature.write(toFile: Config.Server.launchArgsSignatureFile, atomically: true, encoding: .utf8)
        } catch {
            log("failed to write launch args signature: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func launchServer(binary: URL, version: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            log("widget-server binary not found at \(binary.path)")
            return false
        }

        let proc = Process()
        proc.executableURL = binary
        let args = serverLaunchArguments()
        proc.arguments = args
        let environmentOverrides = Config.Server.processEnvironmentOverrides
        if !environmentOverrides.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment
                .merging(environmentOverrides) { _, new in new }
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [version] p in
            log("widget-server \(version) exited with code \(p.terminationStatus)")
        }
        do {
            try proc.run()
            serverProcess = proc
            writeRecordedServerLaunchArgsSignature(serverLaunchArgsSignature())
            log("widget-server started, pid=\(proc.processIdentifier), version=\(version), binary=\(binary.path)")
            return true
        } catch {
            log("failed to start widget-server: \(error.localizedDescription)")
            return false
        }
    }

    func downloadAndStageServer(
        version: String,
        archiveURL: URL,
        downloader: any ServerDownloader
    ) async -> (binary: URL, version: String)? {
        let fm = FileManager.default
        let requestedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let rollingLatestMode = requestedVersion.caseInsensitiveCompare("latest") == .orderedSame

        if !rollingLatestMode {
            let targetBinary = lockedServerBinary(for: requestedVersion)
            if fm.isExecutableFile(atPath: targetBinary.path), canLaunchServerBinary(targetBinary) {
                return (targetBinary, requestedVersion)
            }
        }

        let archiveName = archiveURL.lastPathComponent.isEmpty ? "widget-server.tar.gz" : archiveURL.lastPathComponent

        guard ensureDirectory(managedServerRoot) else {
            return nil
        }

        let stagingRoot = managedServerRoot
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            log("failed to create staging directory: \(error.localizedDescription)")
            return nil
        }
        defer { try? fm.removeItem(at: stagingRoot) }

        let localArchiveURL = stagingRoot.appendingPathComponent(archiveName)

        let showProgress = isBootstrappingServer || isApplyingServerUpdate

        log("downloading widget-server \(version) asset \(archiveName)")
        guard
            await downloadFileWithServerDownloader(
                from: archiveURL,
                to: localArchiveURL,
                downloader: downloader,
                progress: { [weak self] fraction in
                    guard let self, showProgress else {
                        return
                    }
                    let normalized = max(0.0, min(fraction ?? 0.0, 1.0))
                    let mapped = 0.10 + (normalized * 0.60)
                    self.setServerSetupState(
                        .DownloadInflight(phase: "Downloading", progress: mapped)
                    )
                }
            )
        else {
            return nil
        }

        if showProgress {
            setServerSetupState(.DownloadInflight(phase: "Preparing", progress: 0.75))
        }

        let extractedDir = stagingRoot.appendingPathComponent("extract", isDirectory: true)
        do {
            try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        } catch {
            log("failed to create extraction directory: \(error.localizedDescription)")
            return nil
        }

        if showProgress {
            setServerSetupState(.DownloadInflight(phase: "Extracting", progress: 0.85))
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            ServerArchiveUtils.prepareDownloadedArchive(
                archiveURL: localArchiveURL,
                extractedDir: extractedDir,
                binaryName: Config.serverExecutableName,
                requestedVersion: requestedVersion,
                rollingLatestMode: rollingLatestMode
            )
        }.value
        guard let prepared else {
            return nil
        }
        let resolvedVersion = prepared.resolvedVersion

        let finalLockedDir = serverVersionDirectory(for: resolvedVersion, locked: true)
        guard ensureDirectory(finalLockedDir.deletingLastPathComponent()) else {
            return nil
        }
        if fm.fileExists(atPath: finalLockedDir.path) {
            try? fm.removeItem(at: finalLockedDir)
        }
        do {
            if showProgress {
                setServerSetupState(.DownloadInflight(phase: "Installing", progress: 0.92))
            }
            try fm.moveItem(at: extractedDir, to: finalLockedDir)
        } catch {
            log("failed to stage widget-server \(resolvedVersion): \(error.localizedDescription)")
            return nil
        }

        let finalBinary = finalLockedDir.appendingPathComponent(Config.serverExecutableName)
        let isLaunchable = await Task.detached(priority: .userInitiated) {
            ServerArchiveUtils.canLaunchBinary(finalBinary)
        }.value
        guard isLaunchable else {
            try? fm.removeItem(at: finalLockedDir)
            log("staged widget-server \(resolvedVersion) failed post-install validation")
            return nil
        }
        log("staged widget-server \(resolvedVersion) at \(finalBinary.path)")
        return (finalBinary, resolvedVersion)
    }

    func activateDownloadedServer(version: String) -> Bool {
        let fm = FileManager.default
        let activeDir = serverVersionDirectory(for: version)
        let activeBinary = activeDir.appendingPathComponent(Config.serverExecutableName)
        if fm.isExecutableFile(atPath: activeBinary.path), canLaunchServerBinary(activeBinary) {
            setConfiguredServerVersion(version)
            return true
        }

        let lockedDir = serverVersionDirectory(for: version, locked: true)
        guard fm.fileExists(atPath: lockedDir.path) else {
            log("no staged widget-server update found for \(version)")
            return false
        }
        guard ensureDirectory(activeDir.deletingLastPathComponent()) else {
            return false
        }

        let backupDir = managedServerRoot
            .appendingPathComponent(".rollback-\(UUID().uuidString)", isDirectory: true)
        var movedExistingActive = false
        if fm.fileExists(atPath: activeDir.path) {
            do {
                try fm.moveItem(at: activeDir, to: backupDir)
                movedExistingActive = true
            } catch {
                log("failed to move existing widget-server out of the way: \(error.localizedDescription)")
                return false
            }
        }

        do {
            try fm.moveItem(at: lockedDir, to: activeDir)
        } catch {
            if movedExistingActive {
                try? fm.moveItem(at: backupDir, to: activeDir)
            }
            log("failed to activate staged widget-server \(version): \(error.localizedDescription)")
            return false
        }

        guard canLaunchServerBinary(activeBinary) else {
            try? fm.removeItem(at: activeDir)
            if movedExistingActive {
                try? fm.moveItem(at: backupDir, to: activeDir)
            }
            log("activated widget-server \(version) failed validation")
            return false
        }

        if movedExistingActive {
            try? fm.removeItem(at: backupDir)
        }
        setConfiguredServerVersion(version)
        return true
    }

    func removeInstalledServer(version: String) {
        let fm = FileManager.default
        let versionDir = serverVersionDirectory(for: version)
        if fm.fileExists(atPath: versionDir.path) {
            try? fm.removeItem(at: versionDir)
        }
    }

    func removeDownloadedLockedServer(version: String) {
        let fm = FileManager.default
        let lockedDir = serverVersionDirectory(for: version, locked: true)
        if fm.fileExists(atPath: lockedDir.path) {
            try? fm.removeItem(at: lockedDir)
        }
    }

    func uninstallFailedServerNow() {
        stopRunningServer()

        let requiredMajor = requiredServerMajor()
        let configured = configuredServerVersion()
        let candidate = lastServerLaunchAttemptVersion ?? configured
        var removed: [String] = []

        if let candidate {
            removeInstalledServer(version: candidate)
            removeDownloadedLockedServer(version: candidate)
            removed.append(candidate)
            if configured == candidate {
                clearConfiguredServerVersion()
            }
        } else {
            let installed = installedCompatibleVersions(requiredMajor: requiredMajor)
            for version in installed {
                removeInstalledServer(version: version)
                removed.append(version)
            }
            for version in downloadedCompatibleVersions(requiredMajor: requiredMajor) {
                removeDownloadedLockedServer(version: version)
                if !removed.contains(version) {
                    removed.append(version)
                }
            }
            if !removed.isEmpty {
                clearConfiguredServerVersion()
            }
        }

        if !removed.isEmpty {
            log("uninstalled failed widget-server artifacts: \(removed.joined(separator: ", "))")
        } else {
            log("no failed widget-server artifacts found to uninstall")
        }

        bootstrapPromptPosted = false
        pendingBootstrapServerRequiredMajor = requiredMajor
        requestBootstrapPermission(requiredMajor: requiredMajor)
    }

    func waitForServerVersion(_ version: String, timeout: TimeInterval) async -> Bool {
        _ = version
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Health endpoint compatibility:
            // Some widget-server builds return "ok" or an internal build version instead of the
            // distribution folder version. Treat any healthy /health response as ready.
            if await probeRunningServerAsync() != nil {
                if let proc = serverProcess {
                    if proc.isRunning {
                        return true
                    }
                } else {
                    return true
                }
            }
            // Fail fast when the managed widget-server process dies before reporting healthy.
            if let proc = serverProcess, !proc.isRunning {
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func applyDownloadedServerUpdate(version: String) {
        guard !isApplyingServerUpdate else {
            log("widget-server apply already in progress")
            return
        }
        isApplyingServerUpdate = true
        log("applying staged widget-server update \(version)")

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let previous = await self.probeRunningServerAsync()
                ?? self.currentCompatibleServerVersion()

            let lockedBinary = self.lockedServerBinary(for: version)
            let needsDownload = !FileManager.default.isExecutableFile(atPath: lockedBinary.path)
                && !FileManager.default.isExecutableFile(atPath: self.serverBinary(for: version).path)

            if needsDownload {
                self.setServerSetupState(.DownloadInflight(phase: "Checking", progress: 0.05))

                guard let release = await self.fetchLatestRelease(),
                      release.version.trimmingCharacters(in: .whitespacesAndNewlines) == version
                        || version.caseInsensitiveCompare("latest") == .orderedSame
                else {
                    self.isApplyingServerUpdate = false
                    self.setServerSetupState(.Ready(version: previous))
                    self.postNotification(
                        title: Config.displayName,
                        body: Config.Notification.serverUpdateApplyFailedMessage
                    )
                    log("update apply failed: could not fetch release info for \(version)")
                    return
                }
                guard let staged = await self.downloadAndStageServer(
                    version: version,
                    archiveURL: release.archiveURL,
                    downloader: self.makeServerDownloader(for: release.archiveURL)
                ) else {
                    self.isApplyingServerUpdate = false
                    self.setServerSetupState(.Ready(version: previous))
                    self.postNotification(
                        title: Config.displayName,
                        body: Config.Notification.serverUpdateApplyFailedMessage
                    )
                    log("update apply failed: download failed for \(version)")
                    return
                }
                log("update downloaded and staged: \(staged.version)")
            }

            self.setServerSetupState(.DownloadInflight(phase: "Activating", progress: 0.95))

            guard self.activateDownloadedServer(version: version) else {
                self.isApplyingServerUpdate = false
                self.setServerSetupState(.Ready(version: previous))
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.serverUpdateApplyFailedMessage
                )
                return
            }

            self.setServerSetupState(.DownloadInflight(phase: "Starting", progress: 0.98))
            self.stopRunningServer()
            await self.startServer()
            let applied = await self.waitForServerVersion(version, timeout: 8)

            if !applied {
                self.removeInstalledServer(version: version)
                self.stopRunningServer()
                await self.startServer()
                _ = await self.waitForServerVersion(previous, timeout: 8)
            } else {
                self.removeDownloadedLockedServer(version: version)
            }

            self.isApplyingServerUpdate = false
            if applied {
                self.updateState.lastNotifiedServerVersion = nil
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.serverUpdatedMessage(version)
                )
            } else {
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.serverUpdateApplyFailedMessage
                )
            }

            self.runUpdateCheck(force: true, notify: false)
        }
    }
}
