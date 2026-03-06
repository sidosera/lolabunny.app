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
        if isApplyingBackendUpdate || isBootstrappingBackend || isStartingBackend {
            return
        }
        switch backendSetupState {
        case .starting, .waitingForDownloadPermission, .downloading:
            return
        case .ready, .blocked:
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
    }

    func startBackend() async {
        guard !isStartingBackend else {
            return
        }
        isStartingBackend = true
        defer { isStartingBackend = false }

        setBackendSetupState(.starting)
        allowAutomaticBackendDownloads = false
        let requiredMajor = requiredBackendMajor()
        let target = resolveLaunchTarget()
        guard let target else {
            requestBootstrapPermission(requiredMajor: requiredMajor)
            log("no backend binary available to launch")
            return
        }

        allowAutomaticBackendDownloads = true
        let desiredArgsSignature = backendLaunchArgsSignature()

        if let pid = readPidFile(), isProcessRunning(pid), let runningVersion = await probeRunningBackendAsync() {
            if runningVersion == target.version {
                if readRecordedBackendLaunchArgsSignature() == desiredArgsSignature {
                    setBackendSetupState(.ready(version: target.version))
                    log("target backend already running (pid=\(pid), version=\(runningVersion))")
                    return
                }
                log("running backend version \(runningVersion) has stale launch args, restarting")
            } else {
                log("running backend version \(runningVersion) differs from target \(target.version), restarting")
            }
            stopRunningBackend()
        } else if let pid = readPidFile(), isProcessRunning(pid) {
            log("backend pid file exists but health check failed (pid=\(pid)), restarting")
            stopRunningBackend()
        }

        guard launchBackend(binary: target.binary, version: target.version) else {
            setBackendSetupState(.blocked(message: "launch failed"))
            return
        }

        guard await waitForBackendVersion(target.version, timeout: 8) else {
            log("backend failed health check after launch, restarting required")
            stopRunningBackend()
            setBackendSetupState(.blocked(message: "start failed"))
            return
        }
        setBackendSetupState(.ready(version: target.version))
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
}
