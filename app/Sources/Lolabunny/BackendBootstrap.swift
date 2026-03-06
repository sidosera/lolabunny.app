import Foundation

extension AppDelegate {
    func requestBootstrapPermission(requiredMajor: String) {
        pendingBootstrapBackendRequiredMajor = requiredMajor
        setBackendSetupState(.waitingForDownloadPermission(requiredMajor: requiredMajor))
        guard !bootstrapPromptPosted else {
            return
        }
        bootstrapPromptPosted = true
        log("requesting user permission to download backend major \(requiredMajor)")
        postBootstrapPermissionNotification(requiredMajor: requiredMajor)
    }

    func beginBootstrapBackendDownload(requiredMajor: String?) async {
        guard !isBootstrappingBackend else {
            return
        }
        let major = requiredMajor ?? pendingBootstrapBackendRequiredMajor ?? requiredBackendMajor()
        isBootstrappingBackend = true
        allowAutomaticBackendDownloads = true
        setBackendSetupState(.downloading(phase: "Preparing", progress: 0.05))

        let target = await bootstrapBackendFromDistribution(requiredMajor: major)
        isBootstrappingBackend = false

        guard target != nil else {
            allowAutomaticBackendDownloads = false
            setBackendSetupState(.blocked(message: "download failed"))
            postNotification(title: Config.displayName, body: Config.Notification.backendBootstrapFailedMessage)
            return
        }

        bootstrapPromptPosted = false
        pendingBootstrapBackendRequiredMajor = nil
        await startBackend()
    }

    func bootstrapBackendFromDistribution(requiredMajor: String) async -> (binary: URL, version: String)? {
        setBackendSetupState(.downloading(phase: "Checking latest release", progress: 0.10))
        guard let release = await fetchLatestRelease() else {
            log("bootstrap backend download skipped: latest release unavailable")
            return nil
        }
        let version = release.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionMatchesRequiredMajor(version, requiredMajor: requiredMajor) else {
            log("bootstrap backend version \(version) is not compatible with required major \(requiredMajor)")
            return nil
        }
        setBackendSetupState(.downloading(phase: "Selecting artifacts", progress: 0.20))
        guard let selection = selectReleaseAssets(from: release) else {
            log("bootstrap backend selection failed for \(version)")
            return nil
        }
        guard await downloadAndStageBackend(selection: selection) != nil else {
            log("bootstrap backend download failed for \(version)")
            return nil
        }
        setBackendSetupState(.downloading(phase: "Activating backend", progress: 0.92))
        guard activateDownloadedBackend(version: version) else {
            log("bootstrap backend activation failed for \(version)")
            return nil
        }
        let binary = backendBinary(for: version)
        log("bootstrap backend installed \(version) to \(binary.path)")
        setBackendSetupState(.downloading(phase: "Finalizing", progress: 1.0))
        return (binary, version)
    }
}
