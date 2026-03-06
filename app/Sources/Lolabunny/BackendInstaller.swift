import Foundation

extension AppDelegate {
    func downloadAndStageBackend(selection: ReleaseAssetSelection) async -> URL? {
        let fm = FileManager.default
        let version = selection.version
        let targetBinary = lockedBackendBinary(for: version)
        if fm.isExecutableFile(atPath: targetBinary.path), canLaunchBackendBinary(targetBinary) {
            return targetBinary
        }

        let archiveRemoteURL = selection.archive.downloadURL
        let checksumAsset = selection.checksum
        let checksumRemoteURL = checksumAsset.downloadURL

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

        let archiveURL = stagingRoot.appendingPathComponent(selection.archive.name)
        let checksumURL = stagingRoot.appendingPathComponent(checksumAsset.name)

        log("downloading backend \(version) asset \(selection.archive.name)")
        guard
            await downloadFileWithBackendDownloader(
                from: archiveRemoteURL,
                assetName: selection.archive.name,
                to: archiveURL,
                progress: { [weak self] fraction in
                    guard let self, self.isBootstrappingBackend else {
                        return
                    }
                    let normalized = max(0.0, min(fraction ?? 0.0, 1.0))
                    let mapped = 0.30 + (normalized * 0.35)
                    self.setBackendSetupState(
                        .downloading(phase: "Downloading archive", progress: mapped)
                    )
                }
            )
        else {
            return nil
        }

        guard
            await downloadFileWithBackendDownloader(
                from: checksumRemoteURL,
                assetName: checksumAsset.name,
                to: checksumURL,
                progress: { [weak self] fraction in
                    guard let self, self.isBootstrappingBackend else {
                        return
                    }
                    let normalized = max(0.0, min(fraction ?? 0.0, 1.0))
                    let mapped = 0.65 + (normalized * 0.07)
                    self.setBackendSetupState(
                        .downloading(phase: "Downloading checksum", progress: mapped)
                    )
                }
            )
        else {
            return nil
        }

        if isBootstrappingBackend {
            setBackendSetupState(.downloading(phase: "Verifying archive", progress: 0.74))
        }
        guard
            BackendArchiveUtils.verifyDownloadedArchive(
                archiveURL: archiveURL,
                checksumURL: checksumURL,
                archiveName: selection.archive.name
            )
        else {
            return nil
        }

        let extractedDir = stagingRoot.appendingPathComponent("extract", isDirectory: true)
        do {
            try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        } catch {
            log("failed to create extraction directory: \(error.localizedDescription)")
            return nil
        }

        if isBootstrappingBackend {
            setBackendSetupState(.downloading(phase: "Extracting archive", progress: 0.80))
        }
        guard BackendArchiveUtils.extractArchive(archiveURL, to: extractedDir) else {
            return nil
        }

        let extractedBinary = extractedDir.appendingPathComponent(Config.appName)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)
        } catch {
            log("failed to set executable permissions: \(error.localizedDescription)")
        }

        guard canLaunchBackendBinary(extractedBinary) else {
            log("downloaded backend binary is not runnable for current architecture")
            return nil
        }

        let finalLockedDir = backendVersionDirectory(for: version, locked: true)
        guard ensureDirectory(finalLockedDir.deletingLastPathComponent()) else {
            return nil
        }
        if fm.fileExists(atPath: finalLockedDir.path) {
            try? fm.removeItem(at: finalLockedDir)
        }
        do {
            if isBootstrappingBackend {
                setBackendSetupState(.downloading(phase: "Installing backend", progress: 0.90))
            }
            try fm.moveItem(at: extractedDir, to: finalLockedDir)
        } catch {
            log("failed to stage backend \(version): \(error.localizedDescription)")
            return nil
        }

        let finalBinary = finalLockedDir.appendingPathComponent(Config.appName)
        guard canLaunchBackendBinary(finalBinary) else {
            try? fm.removeItem(at: finalLockedDir)
            log("staged backend \(version) failed post-install validation")
            return nil
        }
        log("staged backend \(version) at \(finalBinary.path)")
        return finalBinary
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

    func waitForBackendVersion(_ version: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeRunningBackendAsync() == version {
                return true
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

            guard self.activateDownloadedBackend(version: version) else {
                self.isApplyingBackendUpdate = false
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.backendUpdateApplyFailedMessage
                )
                return
            }

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
