import Foundation

extension AppDelegate {
    func scheduleBackendWatchdog() {
        backendWatchdogTimer?.invalidate()
        backendWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Config.Backend.watchdogIntervalSeconds, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.backendWatchdogTick()
            }
        }
    }

    func backendWatchdogTick() async {
        #if DEBUG
        return
        #else
        if isApplyingBackendUpdate || isBootstrappingBackend || isStartingBackend {
            return
        }
        switch backendSetupState {
        case .GettingReady, .WaitForDownloadPermission, .DownloadInflight:
            return
        case .Ready, .Failed:
            break
        }

        if await probeRunningBackendAsync() != nil {
            return
        }

        if let pid = readPidFile(), isProcessRunning(pid) {
            log("watchdog: backend pid=\(pid) is unresponsive, restarting")
            stopRunningBackend()
        } else {
            log("watchdog: backend is not running, starting")
        }
        await startBackend()
        #endif
    }

    func startBackend() async {
        #if DEBUG
        await startLocalDebugBackend()
        #else
        guard !isStartingBackend else {
            return
        }
        isStartingBackend = true
        defer { isStartingBackend = false }

        let requiredMajor = requiredBackendMajor()
        let target = resolveLaunchTarget()
        guard let target else {
            lastBackendLaunchAttemptVersion = nil
            requestBootstrapPermission(requiredMajor: requiredMajor)
            log("no backend binary available to launch")
            return
        }

        lastBackendLaunchAttemptVersion = target.version
        setBackendSetupState(.GettingReady)
        let desiredArgsSignature = backendLaunchArgsSignature()

        if let pid = readPidFile(), isProcessRunning(pid), await probeRunningBackendAsync() != nil {
            if readRecordedBackendLaunchArgsSignature() == desiredArgsSignature {
                setBackendSetupState(.Ready(version: target.version))
                log("target backend already running (pid=\(pid), target=\(target.version))")
                return
            }
            log("running backend is healthy but has stale launch args, restarting")
            stopRunningBackend()
        } else if let pid = readPidFile(), isProcessRunning(pid) {
            log("backend pid file exists but health check failed (pid=\(pid)), restarting")
            stopRunningBackend()
        }

        guard launchBackend(binary: target.binary, version: target.version) else {
            setBackendSetupState(.Failed(message: "launch failed"))
            return
        }

        guard await waitForBackendVersion(
            target.version,
            timeout: Config.Backend.launchHealthTimeoutSeconds
        ) else {
            log("backend failed health check after launch, restarting required")
            stopRunningBackend()
            setBackendSetupState(.Failed(message: "start failed"))
            return
        }
        setBackendSetupState(.Ready(version: target.version))
        #endif
    }

    func startLocalDebugBackend() async {
        setBackendSetupState(.GettingReady)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let version = await probeRunningBackendAsync() {
                setBackendSetupState(.Ready(version: "dev (\(version.trimmingCharacters(in: .whitespacesAndNewlines)))"))
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        setBackendSetupState(
            .Failed(
                message: "run: swift run --package-path app-server lolabunny serve --port \(Config.backendPort)"
            )
        )
    }

    func requestBootstrapPermission(requiredMajor: String) {
        pendingBootstrapBackendRequiredMajor = requiredMajor
        setBackendSetupState(.WaitForDownloadPermission(requiredMajor: requiredMajor))
        guard !bootstrapPromptPosted else {
            return
        }
        bootstrapPromptPosted = true
        log("requesting user permission to download backend major \(requiredMajor)")
        postBootstrapPermissionNotification(requiredMajor: requiredMajor)
    }

    func beginBootstrapBackendDownload(
        requiredMajor: String?,
        downloader: (any BackendDownloader)? = nil
    ) async {
        guard !isBootstrappingBackend else {
            return
        }
        let major = requiredMajor ?? pendingBootstrapBackendRequiredMajor ?? requiredBackendMajor()
        isBootstrappingBackend = true
        setBackendSetupState(.DownloadInflight(phase: "Preparing", progress: 0.05))

        guard isBackendUpdateSourceConfigured() else {
            isBootstrappingBackend = false
            setBackendSetupState(.Failed(message: "download unavailable: update source is not configured"))
            log("bootstrap download unavailable: update source is not configured")
            return
        }

        let target = await bootstrapBackendFromDistribution(
            requiredMajor: major,
            downloader: downloader
        )
        isBootstrappingBackend = false

        guard target != nil else {
            setBackendSetupState(.Failed(message: "download failed"))
            postNotification(title: Config.displayName, body: Config.Notification.backendBootstrapFailedMessage)
            return
        }

        bootstrapPromptPosted = false
        pendingBootstrapBackendRequiredMajor = nil
        await startBackend()
    }

    func bootstrapBackendFromDistribution(
        requiredMajor: String,
        downloader: (any BackendDownloader)? = nil
    ) async -> (binary: URL, version: String)? {
        setBackendSetupState(.DownloadInflight(phase: "Checking latest release", progress: 0.10))
        guard let release = await fetchLatestRelease() else {
            log("bootstrap backend download skipped: latest release unavailable")
            return nil
        }
        let version = release.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let rollingLatestMode = version.caseInsensitiveCompare("latest") == .orderedSame
        if !rollingLatestMode,
            !versionMatchesRequiredMajor(version, requiredMajor: requiredMajor)
        {
            log("bootstrap backend version \(version) is not compatible with required major \(requiredMajor)")
            return nil
        }
        setBackendSetupState(.DownloadInflight(phase: "Selecting artifacts", progress: 0.20))
        let selectedDownloader = downloader ?? makeBackendDownloader(for: release.archiveURL)
        guard let staged = await downloadAndStageBackend(
            version: version,
            archiveURL: release.archiveURL,
            downloader: selectedDownloader
        ) else {
            log("bootstrap backend download failed for \(version)")
            return nil
        }
        if !versionMatchesRequiredMajor(staged.version, requiredMajor: requiredMajor) {
            removeDownloadedLockedBackend(version: staged.version)
            log("bootstrap backend version \(staged.version) is not compatible with required major \(requiredMajor)")
            return nil
        }
        setBackendSetupState(.DownloadInflight(phase: "Activating backend", progress: 0.92))
        guard activateDownloadedBackend(version: staged.version) else {
            log("bootstrap backend activation failed for \(staged.version)")
            return nil
        }
        let binary = backendBinary(for: staged.version)
        log("bootstrap backend installed \(staged.version) to \(binary.path)")
        setBackendSetupState(.DownloadInflight(phase: "Finalizing", progress: 1.0))
        return (binary, staged.version)
    }

    func readPidFile() -> pid_t? {
        guard let contents = try? String(contentsOfFile: Config.Backend.pidFile, encoding: .utf8) else {
            return nil
        }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    func stopRunningBackend() {
        if let proc = backendProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            backendProcess = nil
            log("stopped managed backend process")
            return
        }
        if let pid = readPidFile(), isProcessRunning(pid) {
            kill(pid, SIGTERM)
            log("sent SIGTERM to backend pid=\(pid)")
            usleep(500_000)
        }
    }

    func probeRunningBackendAsync() async -> String? {
        let url = Config.backendBaseURL.appendingPathComponent("health")
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
        Config.Backend.version
    }

    func majorVersion(_ version: String) -> String {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return String(v.prefix(while: { $0 != "." }))
    }

    func backendLaunchArguments() -> [String] {
        var args = [
            "serve",
            "--port", "\(Config.backendPort)",
            "--address", Config.Backend.address,
            "--log-level", Config.Backend.logLevel,
            "--default-search", Config.Backend.defaultSearch,
            "--history-enabled", Config.Backend.historyEnabled ? "true" : "false",
            "--history-max-entries", "\(Config.Backend.historyMaxEntries)"
        ]
        if let volumePath = Config.Backend.volumePath {
            args += ["--volume-path", volumePath]
        }
        return args
    }

    func backendLaunchArgsSignature() -> String {
        backendLaunchArguments().joined(separator: "\n")
    }

    func readRecordedBackendLaunchArgsSignature() -> String? {
        guard let value = try? String(contentsOfFile: Config.Backend.launchArgsSignatureFile, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func writeRecordedBackendLaunchArgsSignature(_ signature: String) {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Config.Backend.runtimeDir, isDirectory: true),
                withIntermediateDirectories: true
            )
            try signature.write(toFile: Config.Backend.launchArgsSignatureFile, atomically: true, encoding: .utf8)
        } catch {
            log("failed to write launch args signature: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func launchBackend(binary: URL, version: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            log("backend binary not found at \(binary.path)")
            return false
        }

        let proc = Process()
        proc.executableURL = binary
        let args = backendLaunchArguments()
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [version] p in
            log("backend \(version) exited with code \(p.terminationStatus)")
        }
        do {
            try proc.run()
            backendProcess = proc
            writeRecordedBackendLaunchArgsSignature(backendLaunchArgsSignature())
            log("backend started, pid=\(proc.processIdentifier), version=\(version), binary=\(binary.path)")
            return true
        } catch {
            log("failed to start backend: \(error.localizedDescription)")
            return false
        }
    }

    func downloadAndStageBackend(
        version: String,
        archiveURL: URL,
        downloader: any BackendDownloader
    ) async -> (binary: URL, version: String)? {
        let fm = FileManager.default
        let requestedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let rollingLatestMode = requestedVersion.caseInsensitiveCompare("latest") == .orderedSame

        if !rollingLatestMode {
            let targetBinary = lockedBackendBinary(for: requestedVersion)
            if fm.isExecutableFile(atPath: targetBinary.path), canLaunchBackendBinary(targetBinary) {
                return (targetBinary, requestedVersion)
            }
        }

        let archiveName = archiveURL.lastPathComponent.isEmpty ? "backend.tar.gz" : archiveURL.lastPathComponent

        guard ensureDirectory(managedBackendRoot) else {
            return nil
        }

        let stagingRoot = managedBackendRoot
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            log("failed to create staging directory: \(error.localizedDescription)")
            return nil
        }
        defer { try? fm.removeItem(at: stagingRoot) }

        let localArchiveURL = stagingRoot.appendingPathComponent(archiveName)

        let showProgress = isBootstrappingBackend || isApplyingBackendUpdate

        log("downloading backend \(version) asset \(archiveName)")
        guard
            await downloadFileWithBackendDownloader(
                from: archiveURL,
                to: localArchiveURL,
                downloader: downloader,
                progress: { [weak self] fraction in
                    guard let self, showProgress else {
                        return
                    }
                    let normalized = max(0.0, min(fraction ?? 0.0, 1.0))
                    let mapped = 0.10 + (normalized * 0.60)
                    self.setBackendSetupState(
                        .DownloadInflight(phase: "Downloading", progress: mapped)
                    )
                }
            )
        else {
            return nil
        }

        if showProgress {
            setBackendSetupState(.DownloadInflight(phase: "Preparing", progress: 0.75))
        }

        let extractedDir = stagingRoot.appendingPathComponent("extract", isDirectory: true)
        do {
            try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        } catch {
            log("failed to create extraction directory: \(error.localizedDescription)")
            return nil
        }

        if showProgress {
            setBackendSetupState(.DownloadInflight(phase: "Extracting", progress: 0.85))
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            BackendArchiveUtils.prepareDownloadedArchive(
                archiveURL: localArchiveURL,
                extractedDir: extractedDir,
                binaryName: Config.appName,
                requestedVersion: requestedVersion,
                rollingLatestMode: rollingLatestMode
            )
        }.value
        guard let prepared else {
            return nil
        }
        let resolvedVersion = prepared.resolvedVersion

        let finalLockedDir = backendVersionDirectory(for: resolvedVersion, locked: true)
        guard ensureDirectory(finalLockedDir.deletingLastPathComponent()) else {
            return nil
        }
        if fm.fileExists(atPath: finalLockedDir.path) {
            try? fm.removeItem(at: finalLockedDir)
        }
        do {
            if showProgress {
                setBackendSetupState(.DownloadInflight(phase: "Installing", progress: 0.92))
            }
            try fm.moveItem(at: extractedDir, to: finalLockedDir)
        } catch {
            log("failed to stage backend \(resolvedVersion): \(error.localizedDescription)")
            return nil
        }

        let finalBinary = finalLockedDir.appendingPathComponent(Config.appName)
        let isLaunchable = await Task.detached(priority: .userInitiated) {
            BackendArchiveUtils.canLaunchBinary(finalBinary)
        }.value
        guard isLaunchable else {
            try? fm.removeItem(at: finalLockedDir)
            log("staged backend \(resolvedVersion) failed post-install validation")
            return nil
        }
        log("staged backend \(resolvedVersion) at \(finalBinary.path)")
        return (finalBinary, resolvedVersion)
    }

    func activateDownloadedBackend(version: String) -> Bool {
        let fm = FileManager.default
        let activeDir = backendVersionDirectory(for: version)
        let activeBinary = activeDir.appendingPathComponent(Config.appName)
        if fm.isExecutableFile(atPath: activeBinary.path), canLaunchBackendBinary(activeBinary) {
            setConfiguredBackendVersion(version)
            return true
        }

        let lockedDir = backendVersionDirectory(for: version, locked: true)
        guard fm.fileExists(atPath: lockedDir.path) else {
            log("no staged backend update found for \(version)")
            return false
        }
        guard ensureDirectory(activeDir.deletingLastPathComponent()) else {
            return false
        }

        let backupDir = managedBackendRoot
            .appendingPathComponent(".rollback-\(UUID().uuidString)", isDirectory: true)
        var movedExistingActive = false
        if fm.fileExists(atPath: activeDir.path) {
            do {
                try fm.moveItem(at: activeDir, to: backupDir)
                movedExistingActive = true
            } catch {
                log("failed to move existing backend out of the way: \(error.localizedDescription)")
                return false
            }
        }

        do {
            try fm.moveItem(at: lockedDir, to: activeDir)
        } catch {
            if movedExistingActive {
                try? fm.moveItem(at: backupDir, to: activeDir)
            }
            log("failed to activate staged backend \(version): \(error.localizedDescription)")
            return false
        }

        guard canLaunchBackendBinary(activeBinary) else {
            try? fm.removeItem(at: activeDir)
            if movedExistingActive {
                try? fm.moveItem(at: backupDir, to: activeDir)
            }
            log("activated backend \(version) failed validation")
            return false
        }

        if movedExistingActive {
            try? fm.removeItem(at: backupDir)
        }
        setConfiguredBackendVersion(version)
        return true
    }

    func removeInstalledBackend(version: String) {
        let fm = FileManager.default
        let versionDir = backendVersionDirectory(for: version)
        if fm.fileExists(atPath: versionDir.path) {
            try? fm.removeItem(at: versionDir)
        }
    }

    func removeDownloadedLockedBackend(version: String) {
        let fm = FileManager.default
        let lockedDir = backendVersionDirectory(for: version, locked: true)
        if fm.fileExists(atPath: lockedDir.path) {
            try? fm.removeItem(at: lockedDir)
        }
    }

    func uninstallFailedBackendNow() {
        stopRunningBackend()

        let requiredMajor = requiredBackendMajor()
        let configured = configuredBackendVersion()
        let candidate = lastBackendLaunchAttemptVersion ?? configured
        var removed: [String] = []

        if let candidate {
            removeInstalledBackend(version: candidate)
            removeDownloadedLockedBackend(version: candidate)
            removed.append(candidate)
            if configured == candidate {
                clearConfiguredBackendVersion()
            }
        } else {
            let installed = installedCompatibleVersions(requiredMajor: requiredMajor)
            for version in installed {
                removeInstalledBackend(version: version)
                removed.append(version)
            }
            for version in downloadedCompatibleVersions(requiredMajor: requiredMajor) {
                removeDownloadedLockedBackend(version: version)
                if !removed.contains(version) {
                    removed.append(version)
                }
            }
            if !removed.isEmpty {
                clearConfiguredBackendVersion()
            }
        }

        if !removed.isEmpty {
            log("uninstalled failed backend artifacts: \(removed.joined(separator: ", "))")
        } else {
            log("no failed backend artifacts found to uninstall")
        }

        bootstrapPromptPosted = false
        pendingBootstrapBackendRequiredMajor = requiredMajor
        requestBootstrapPermission(requiredMajor: requiredMajor)
    }

    func waitForBackendVersion(_ version: String, timeout: TimeInterval) async -> Bool {
        _ = version
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Health endpoint compatibility:
            // Some backend builds return "ok" or an internal build version instead of the
            // distribution folder version. Treat any healthy /health response as ready.
            if await probeRunningBackendAsync() != nil {
                if let proc = backendProcess {
                    if proc.isRunning {
                        return true
                    }
                } else {
                    return true
                }
            }
            // Fail fast when the managed backend process dies before reporting healthy.
            if let proc = backendProcess, !proc.isRunning {
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func applyDownloadedBackendUpdate(version: String) {
        guard !isApplyingBackendUpdate else {
            log("backend apply already in progress")
            return
        }
        isApplyingBackendUpdate = true
        log("applying staged backend update \(version)")

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let previous = await self.probeRunningBackendAsync()
                ?? self.currentCompatibleBackendVersion()

            let lockedBinary = self.lockedBackendBinary(for: version)
            let needsDownload = !FileManager.default.isExecutableFile(atPath: lockedBinary.path)
                && !FileManager.default.isExecutableFile(atPath: self.backendBinary(for: version).path)

            if needsDownload {
                self.setBackendSetupState(.DownloadInflight(phase: "Checking", progress: 0.05))

                guard let release = await self.fetchLatestRelease(),
                      release.version.trimmingCharacters(in: .whitespacesAndNewlines) == version
                        || version.caseInsensitiveCompare("latest") == .orderedSame
                else {
                    self.isApplyingBackendUpdate = false
                    self.setBackendSetupState(.Ready(version: previous))
                    self.postNotification(
                        title: Config.displayName,
                        body: Config.Notification.backendUpdateApplyFailedMessage
                    )
                    log("update apply failed: could not fetch release info for \(version)")
                    return
                }
                guard let staged = await self.downloadAndStageBackend(
                    version: version,
                    archiveURL: release.archiveURL,
                    downloader: self.makeBackendDownloader(for: release.archiveURL)
                ) else {
                    self.isApplyingBackendUpdate = false
                    self.setBackendSetupState(.Ready(version: previous))
                    self.postNotification(
                        title: Config.displayName,
                        body: Config.Notification.backendUpdateApplyFailedMessage
                    )
                    log("update apply failed: download failed for \(version)")
                    return
                }
                log("update downloaded and staged: \(staged.version)")
            }

            self.setBackendSetupState(.DownloadInflight(phase: "Activating", progress: 0.95))

            guard self.activateDownloadedBackend(version: version) else {
                self.isApplyingBackendUpdate = false
                self.setBackendSetupState(.Ready(version: previous))
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.backendUpdateApplyFailedMessage
                )
                return
            }

            self.setBackendSetupState(.DownloadInflight(phase: "Starting", progress: 0.98))
            self.stopRunningBackend()
            await self.startBackend()
            let applied = await self.waitForBackendVersion(version, timeout: 8)

            if !applied {
                self.removeInstalledBackend(version: version)
                self.stopRunningBackend()
                await self.startBackend()
                _ = await self.waitForBackendVersion(previous, timeout: 8)
            } else {
                self.removeDownloadedLockedBackend(version: version)
            }

            self.isApplyingBackendUpdate = false
            if applied {
                self.updateState.lastNotifiedBackendVersion = nil
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.backendUpdatedMessage(version)
                )
            } else {
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.backendUpdateApplyFailedMessage
                )
            }

            self.runUpdateCheck(force: true, notify: false)
        }
    }
}
