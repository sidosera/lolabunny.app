import Cocoa

extension AppDelegate {
    func hostMachineIdentifier() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    func isRosettaTranslated() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return rc == 0 && translated == 1
    }

    func architectureAliases() -> [String] {
        let machine = hostMachineIdentifier().lowercased()
        if isRosettaTranslated() || machine.contains("x86_64") || machine.contains("amd64") {
            return ["x86_64", "amd64", "x64", "universal"]
        }
        if machine.contains("arm64") || machine.contains("aarch64") {
            return ["arm64", "aarch64", "universal"]
        }
        return [machine, "universal"]
    }

    func architectureStorageKey() -> String {
        let aliases = architectureAliases()
        if aliases.contains("arm64") { return "arm64" }
        if aliases.contains("x86_64") { return "x86_64" }
        return aliases.first ?? "unknown"
    }

    func architectureLabel() -> String {
        hostMachineIdentifier()
    }

    func shouldSkipAutomaticUpdateChecks() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func managedServerBinary(for version: String) -> URL {
        managedServerRoot
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(architectureStorageKey(), isDirectory: true)
            .appendingPathComponent(Config.appName)
    }

    func pendingServerBinary(for version: String) -> URL {
        pendingServerRoot
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(architectureStorageKey(), isDirectory: true)
            .appendingPathComponent(Config.appName)
    }

    func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            log("failed to create directory \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    func canLaunchServerBinary(_ binary: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return false
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            log("binary not launchable (\(binary.path)): \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            log("binary version probe failed (\(binary.path)), exit=\(proc.terminationStatus)")
            return false
        }
        return true
    }

    func installedServerVersions() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: managedServerRoot.path) else {
            return []
        }
        return entries.filter { version in
            if version.hasPrefix(".") {
                return false
            }
            return fm.isExecutableFile(atPath: managedServerBinary(for: version).path)
        }
    }

    func parseSemVer(_ version: String) -> SemVer? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else {
            return nil
        }

        let patchDigits = parts[2].prefix { $0.isNumber }
        guard !patchDigits.isEmpty, let patch = Int(patchDigits) else {
            return nil
        }
        return SemVer(major: major, minor: minor, patch: patch)
    }

    func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = parseSemVer(lhs), let right = parseSemVer(rhs) {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return lhs.compare(rhs, options: .numeric)
    }

    func requiredServerMajor() -> String {
        majorVersion(bundledVersion())
    }

    func versionMatchesRequiredMajor(_ version: String, requiredMajor: String) -> Bool {
        let expectedMajor = requiredMajor.trimmingCharacters(in: .whitespacesAndNewlines)
        if expectedMajor.isEmpty {
            // Dev or non-semver app versions may not define a strict server major.
            return true
        }
        return majorVersion(version) == expectedMajor
    }

    func currentCompatibleServerVersion() -> String {
        let bundled = bundledVersion()
        return installedCompatibleVersions(requiredMajor: requiredServerMajor()).first ?? bundled
    }

    func installedCompatibleVersions(requiredMajor: String) -> [String] {
        installedServerVersions()
            .filter { versionMatchesRequiredMajor($0, requiredMajor: requiredMajor) }
            .sorted { compareVersions($0, $1) == .orderedDescending }
    }

    func resolveLaunchTarget() -> (binary: URL, version: String)? {
        for version in installedCompatibleVersions(requiredMajor: requiredServerMajor()) {
            let candidate = managedServerBinary(for: version)
            if canLaunchServerBinary(candidate) {
                return (candidate, version)
            }
            log("cached server \(version) is not runnable, skipping")
        }
        return nil
    }

    func requestBootstrapPermission(requiredMajor: String) {
        pendingBootstrapRequiredMajor = requiredMajor
        setServerSetupState(.waitingForDownloadPermission(requiredMajor: requiredMajor))
        guard !bootstrapPromptPosted else {
            return
        }
        bootstrapPromptPosted = true
        log("requesting user permission to download server major \(requiredMajor)")
        postBootstrapPermissionNotification(requiredMajor: requiredMajor)
    }

    func beginBootstrapDownload(requiredMajor: String?) async {
        guard !isBootstrappingServer else {
            return
        }
        let major = requiredMajor ?? pendingBootstrapRequiredMajor ?? requiredServerMajor()
        isBootstrappingServer = true
        allowAutomaticServerDownloads = true
        setServerSetupState(.downloading(phase: "Preparing", progress: 0.05))

        let target = await bootstrapServerFromDistribution(requiredMajor: major)
        isBootstrappingServer = false

        guard target != nil else {
            allowAutomaticServerDownloads = false
            setServerSetupState(.blocked(message: "download failed"))
            postNotification(title: Config.displayName, body: Config.Notification.serverBootstrapFailedMessage)
            return
        }

        bootstrapPromptPosted = false
        pendingBootstrapRequiredMajor = nil
        await startServer()
    }

    func bootstrapServerFromDistribution(requiredMajor: String) async -> (binary: URL, version: String)? {
        setServerSetupState(.downloading(phase: "Checking latest release", progress: 0.10))
        guard let release = await fetchLatestRelease() else {
            log("bootstrap server download skipped: latest release unavailable")
            return nil
        }
        let version = release.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionMatchesRequiredMajor(version, requiredMajor: requiredMajor) else {
            log("bootstrap server version \(version) is not compatible with required major \(requiredMajor)")
            return nil
        }
        setServerSetupState(.downloading(phase: "Selecting artifacts", progress: 0.20))
        guard let selection = selectReleaseAssets(from: release) else {
            log("bootstrap server selection failed for \(version)")
            return nil
        }
        guard await downloadAndStageServer(selection: selection) != nil else {
            log("bootstrap server download failed for \(version)")
            return nil
        }
        setServerSetupState(.downloading(phase: "Activating server", progress: 0.92))
        guard promotePendingServer(version: version) else {
            log("bootstrap server activation failed for \(version)")
            return nil
        }
        removePendingServer(version: version)
        let binary = managedServerBinary(for: version)
        guard canLaunchServerBinary(binary) else {
            log("bootstrap server \(version) is not runnable after activation")
            return nil
        }
        log("bootstrap server installed \(version) to \(binary.path)")
        setServerSetupState(.downloading(phase: "Finalizing", progress: 1.0))
        return (binary, version)
    }

    func startServer() async {
        setServerSetupState(.starting)
        allowAutomaticServerDownloads = false
        let requiredMajor = requiredServerMajor()
        let target = resolveLaunchTarget()
        guard let target else {
            requestBootstrapPermission(requiredMajor: requiredMajor)
            log("no server binary available to launch")
            return
        }

        allowAutomaticServerDownloads = true

        if let pid = readPidFile(), isProcessRunning(pid), let runningVersion = await probeRunningServerAsync() {
            if runningVersion == target.version {
                setServerSetupState(.ready(version: target.version))
                log("target server already running (pid=\(pid), version=\(runningVersion))")
                return
            }
            log("running server version \(runningVersion) differs from target \(target.version), restarting")
            stopRunningServer()
        } else if let pid = readPidFile(), isProcessRunning(pid) {
            log("server pid file exists but health check failed (pid=\(pid)), restarting")
            stopRunningServer()
        }

        launchServerProcess(binary: target.binary, version: target.version)
        setServerSetupState(.ready(version: target.version))
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
        if let proc = serverProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            serverProcess = nil
            log("stopped managed server process")
            return
        }
        if let pid = readPidFile(), isProcessRunning(pid) {
            kill(pid, SIGTERM)
            log("sent SIGTERM to server pid=\(pid)")
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

    func launchServerProcess(binary: URL, version: String) {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            log("server binary not found at \(binary.path)")
            return
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve", "--port", "\(Config.serverPort)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [version] p in
            log("server \(version) exited with code \(p.terminationStatus)")
        }
        do {
            try proc.run()
            serverProcess = proc
            log("server started, pid=\(proc.processIdentifier), version=\(version), binary=\(binary.path)")
        } catch {
            log("failed to start server: \(error.localizedDescription)")
        }
    }
}
