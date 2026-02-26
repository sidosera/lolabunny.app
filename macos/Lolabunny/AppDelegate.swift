import Cocoa
import CryptoKit
import os.log
import ServiceManagement
import UserNotifications

private enum Config {
    static let bundleIdentifier = "com.sidosera.lolabunny"
    static let appName          = "lolabunny"
    static let displayName      = "Lolabunny"
    static let serverPort: UInt16 = 8085
    static let serverURL        = "http://localhost:\(serverPort)"

    enum Icon {
        static let size      = NSSize(width: 18, height: 18)
        static let variants  = ["bunny", "bunny@2x"]
        static let fileType  = "png"
    }

    enum Log {
        static let path = NSHomeDirectory() + "/Library/Logs/\(Config.appName).log"
    }

    enum Server {
        static let runtimeDir = NSTemporaryDirectory() + ".lolabunny"
        static let pidFile    = runtimeDir + "/pid"
        static let xdgPrefix  = "bunnylol"
        static let githubOwner = "sidosera"
        static let githubRepo = "lolabunny.app"
        static let latestReleaseAPI = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest"
        static let dataHome: String = {
            let env = ProcessInfo.processInfo.environment
            if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
                return xdg
            }
            return NSHomeDirectory() + "/.local/share"
        }()
        static let installRoot = dataHome + "/\(xdgPrefix)/servers"
        static let version: String = {
            guard let path = Bundle.main.path(forResource: ".version", ofType: nil),
                  let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return "unknown"
            }
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
    }

    enum Brew {
        static let candidates   = ["/opt/homebrew", "/usr/local"]
        static let defaultPATH  = "/usr/bin:/bin:/usr/sbin:/sbin"
        static let prefix: String = {
            let fm = FileManager.default
            for path in candidates {
                if fm.isExecutableFile(atPath: path + "/bin/brew") {
                    return path
                }
            }
            #if arch(arm64)
            return "/opt/homebrew"
            #else
            return "/usr/local"
            #endif
        }()
        static let executable = prefix + "/bin/brew"
        static let pluginDir  = prefix + "/share/" + Config.appName + "/commands"
    }

    enum Menu {
        static let openBindings   = "Open Bindings"
        static let restartServer  = "Restart Server"
        static let updateServer   = "Update Server"
        static let updatePlugins  = "Update Plugins"
        static let launchAtLogin  = "Launch at Login"
        static let quit           = "Quit"
    }

    enum Notification {
        static let identifier = "lolabunny-notification"
        static let pluginsUpdatedMessage = "Plugins updated."
        static let pluginUpdateFailureMessage = "Plugin update failed."
        static let serverUpdateFailureMessage = "Server update failed."
        static func serverUnavailableMessage(_ arch: String, _ version: String) -> String {
            "No compatible server artifact for \(arch). Keeping \(version)."
        }
        static func serverUpdatedMessage(_ version: String) -> String {
            "Server updated to \(version)."
        }
        static func serverUpToDateMessage(_ version: String) -> String {
            "Server is up to date (\(version))."
        }
    }
}

private let logger = OSLog(subsystem: Config.bundleIdentifier, category: "app")

private func log(_ message: String) {
    os_log("%{public}s", log: logger, type: .default, message)
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    if let fh = FileHandle(forWritingAtPath: Config.Log.path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: Config.Log.path, contents: line.data(using: .utf8))
    }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
}

private struct ReleaseAssetSelection {
    let version: String
    let archive: GitHubAsset
    let checksum: GitHubAsset?
}

private struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

private enum ServerUpdateResult {
    case updated(version: String)
    case upToDate(version: String)
    case unavailable(currentVersion: String, arch: String)
    case failed
}

private enum BrewManager {
    static func installedFormulas() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Config.Brew.pluginDir) else {
            return []
        }
        return entries.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: Config.Brew.pluginDir + "/" + name, isDirectory: &isDir)
                && isDir.boolValue
        }
    }

    @discardableResult
    static func upgradeAll() -> Bool {
        let formulas = installedFormulas()
        log("discovered formulas: \(formulas)")
        guard !formulas.isEmpty else {
            log("no formulas found, skipping")
            return true
        }
        let args = ["upgrade", "--fetch-HEAD"] + formulas
        log("running brew \(args.joined(separator: " "))")
        return run(arguments: args)
    }

    private static func run(arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Config.Brew.executable)
        proc.arguments = arguments
        proc.environment = shellEnvironment()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            log("failed to launch brew: \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log("brew exit=\(proc.terminationStatus) stdout=\(stdout) stderr=\(stderr)")
        return proc.terminationStatus == 0
    }

    private static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brewBin = Config.Brew.prefix + "/bin"
        let path = env["PATH"] ?? Config.Brew.defaultPATH
        if !path.contains(brewBin) {
            env["PATH"] = brewBin + ":" + path
        }
        return env
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var isUpdatingPlugins = false
    private var isUpdatingServer = false

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(updateServer(_:)) {
            return !isUpdatingServer
        }
        if menuItem.action == #selector(updatePlugins(_:)) {
            return !isUpdatingPlugins
        }
        return true
    }

    func applicationDidFinishLaunching(_: Notification) {
        log("app launched, pluginDir=\(Config.Brew.pluginDir), arch=\(architectureLabel()), serverRoot=\(managedServerRoot.path)")
        setupStatusBar()
        startServer()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            log("notification auth: granted=\(granted) error=\(String(describing: error))")
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = makeStatusBarIcon()
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: Config.Menu.openBindings, action: #selector(openBindings), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: Config.Menu.restartServer, action: #selector(restartServer), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: Config.Menu.updateServer, action: #selector(updateServer), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: Config.Menu.updatePlugins, action: #selector(updatePlugins), keyEquivalent: "p"))
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: Config.Menu.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Config.Menu.quit, action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    private func makeStatusBarIcon() -> NSImage {
        let icon = NSImage(size: Config.Icon.size)
        var loaded = false

        for name in Config.Icon.variants {
            guard let path = Bundle.main.path(forResource: name, ofType: Config.Icon.fileType),
                  let img = NSImage(contentsOfFile: path),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
            else { continue }
            rep.size = Config.Icon.size
            icon.addRepresentation(rep)
            loaded = true
        }

        guard loaded else { return makeFallbackIcon() }
        icon.isTemplate = true
        return icon
    }

    private func makeFallbackIcon() -> NSImage {
        let image = NSImage(size: Config.Icon.size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 1, width: 14, height: 12)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private var serverProcess: Process?

    private var bundledServerBinary: URL {
        Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent(Config.appName)
    }

    private var managedServerRoot: URL {
        URL(fileURLWithPath: Config.Server.installRoot, isDirectory: true)
    }

    private func hostMachineIdentifier() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private func isRosettaTranslated() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return rc == 0 && translated == 1
    }

    private func architectureAliases() -> [String] {
        let machine = hostMachineIdentifier().lowercased()
        if isRosettaTranslated() || machine.contains("x86_64") || machine.contains("amd64") {
            return ["x86_64", "amd64", "x64", "universal"]
        }
        if machine.contains("arm64") || machine.contains("aarch64") {
            return ["arm64", "aarch64", "universal"]
        }
        return [machine, "universal"]
    }

    private func architectureStorageKey() -> String {
        let aliases = architectureAliases()
        if aliases.contains("arm64") { return "arm64" }
        if aliases.contains("x86_64") { return "x86_64" }
        return aliases.first ?? "unknown"
    }

    private func architectureLabel() -> String {
        hostMachineIdentifier()
    }

    private func managedServerBinary(for version: String) -> URL {
        managedServerRoot
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(architectureStorageKey(), isDirectory: true)
            .appendingPathComponent(Config.appName)
    }

    private func isServerArchiveAsset(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains(Config.appName)
            && (n.contains("darwin") || n.contains("macos"))
            && n.hasSuffix(".tar.gz")
            && !n.hasSuffix(".tar.gz.sha256")
    }

    private func matchesArch(_ assetName: String, archToken: String) -> Bool {
        let n = assetName.lowercased()
        let t = archToken.lowercased()
        return n.contains("-\(t).") || n.contains("-\(t)-") || n.hasSuffix("\(t).tar.gz")
    }

    private func selectReleaseAssets(from release: GitHubRelease) -> ReleaseAssetSelection? {
        let archives = release.assets.filter { isServerArchiveAsset($0.name) }
        guard !archives.isEmpty else {
            log("latest release \(release.tag_name) has no macOS server archives")
            return nil
        }

        let aliases = architectureAliases()
        var selectedArchive: GitHubAsset?
        for alias in aliases {
            if let match = archives.first(where: { matchesArch($0.name, archToken: alias) }) {
                selectedArchive = match
                break
            }
        }
        if selectedArchive == nil,
           let universal = archives.first(where: { $0.name.lowercased().contains("universal") }) {
            selectedArchive = universal
        }
        if selectedArchive == nil, archives.count == 1 {
            selectedArchive = archives[0]
        }
        guard let archive = selectedArchive else {
            log("no matching server archive for architecture \(architectureAliases()) in release \(release.tag_name)")
            return nil
        }

        let checksumName = archive.name + ".sha256"
        let checksum = release.assets.first { $0.name == checksumName }
        guard checksum != nil else {
            log("checksum asset missing for archive \(archive.name)")
            return nil
        }
        return ReleaseAssetSelection(
            version: release.tag_name.trimmingCharacters(in: .whitespacesAndNewlines),
            archive: archive,
            checksum: checksum
        )
    }

    private func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            log("failed to create directory \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    private func canLaunchServerBinary(_ binary: URL) -> Bool {
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

    private func installBundledServerIfNeeded(version: String) -> URL? {
        let fm = FileManager.default
        let source = bundledServerBinary
        let target = managedServerBinary(for: version)

        guard fm.isExecutableFile(atPath: source.path) else {
            log("bundled server binary not found at \(source.path)")
            return nil
        }
        guard ensureDirectory(target.deletingLastPathComponent()) else {
            return nil
        }
        if fm.isExecutableFile(atPath: target.path), canLaunchServerBinary(target) {
            return target
        }

        do {
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            guard canLaunchServerBinary(target) else {
                try? fm.removeItem(at: target)
                log("bundled server at \(target.path) is not runnable")
                return nil
            }
            log("installed bundled server \(version) to \(target.path)")
            return target
        } catch {
            log("failed to install bundled server \(version): \(error.localizedDescription)")
            return nil
        }
    }

    private func installedServerVersions() -> [String] {
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

    private func parseSemVer(_ version: String) -> SemVer? {
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

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = parseSemVer(lhs), let right = parseSemVer(rhs) {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return lhs.compare(rhs, options: .numeric)
    }

    private func installedCompatibleVersions(requiredMajor: String) -> [String] {
        installedServerVersions()
            .filter { majorVersion($0) == requiredMajor }
            .sorted { compareVersions($0, $1) == .orderedDescending }
    }

    private func resolveLaunchTarget() -> (binary: URL, version: String)? {
        let bundled = bundledVersion()
        _ = installBundledServerIfNeeded(version: bundled)
        let requiredMajor = majorVersion(bundled)

        for version in installedCompatibleVersions(requiredMajor: requiredMajor) {
            let candidate = managedServerBinary(for: version)
            if canLaunchServerBinary(candidate) {
                return (candidate, version)
            }
            log("cached server \(version) is not runnable, skipping")
        }
        if let cachedBundled = installBundledServerIfNeeded(version: bundled) {
            return (cachedBundled, bundled)
        }
        if canLaunchServerBinary(bundledServerBinary) {
            return (bundledServerBinary, bundled)
        }
        return nil
    }

    private func startServer(checkForUpdates: Bool = true) {
        guard let target = resolveLaunchTarget() else {
            log("no server binary available to launch")
            return
        }

        if let pid = readPidFile(), isProcessRunning(pid), let runningVersion = probeRunningServer() {
            if runningVersion == target.version {
                log("target server already running (pid=\(pid), version=\(runningVersion))")
                if checkForUpdates {
                    updateServerInBackground(notifyWhenCurrent: false)
                }
                return
            }
            log("running server version \(runningVersion) differs from target \(target.version), restarting")
            stopRunningServer()
        } else if let pid = readPidFile(), isProcessRunning(pid) {
            log("server pid file exists but health check failed (pid=\(pid)), restarting")
            stopRunningServer()
        }

        launchServerProcess(binary: target.binary, version: target.version)

        if checkForUpdates {
            updateServerInBackground(notifyWhenCurrent: false)
        }
    }

    private func readPidFile() -> pid_t? {
        guard let contents = try? String(contentsOfFile: Config.Server.pidFile, encoding: .utf8) else {
            return nil
        }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func stopRunningServer() {
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

    private func probeRunningServer() -> String? {
        let url = URL(string: "\(Config.serverURL)/health")!
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        let task = URLSession.shared.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data = data, let version = String(data: data, encoding: .utf8) {
                result = version.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2)
        return result
    }

    private func bundledVersion() -> String {
        Config.Server.version
    }

    private func majorVersion(_ version: String) -> String {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return String(v.prefix(while: { $0 != "." }))
    }

    private func fetchLatestRelease() -> GitHubRelease? {
        guard let url = URL(string: Config.Server.latestReleaseAPI) else {
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(Config.displayName, forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var releaseResult: GitHubRelease?
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                log("latest release check failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                log("latest release check failed: missing HTTP response")
                return
            }
            guard http.statusCode == 200, let data else {
                log("latest release check failed: status=\(http.statusCode)")
                return
            }
            guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                log("latest release check failed: invalid response payload")
                return
            }
            releaseResult = release
        }
        task.resume()
        if sem.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            log("latest release check timed out")
            return nil
        }
        return releaseResult
    }

    private func downloadFile(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var success = false

        var req = URLRequest(url: sourceURL)
        req.timeoutInterval = 120
        req.setValue(Config.displayName, forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.downloadTask(with: req) { tempURL, response, error in
            defer { sem.signal() }
            if let error {
                log("download failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                log("download failed: missing HTTP response")
                return
            }
            guard (200 ... 299).contains(http.statusCode), let tempURL else {
                log("download failed: status=\(http.statusCode)")
                return
            }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.moveItem(at: tempURL, to: destinationURL)
                success = true
            } catch {
                log("failed to persist downloaded archive: \(error.localizedDescription)")
            }
        }
        task.resume()

        if sem.wait(timeout: .now() + 140) == .timedOut {
            task.cancel()
            log("download timed out: \(sourceURL.absoluteString)")
            return false
        }
        return success
    }

    private func sha256Hex(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            log("failed to read \(fileURL.path) for sha256")
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func parseExpectedSHA256(contents: String, archiveName: String) -> String? {
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

    private func verifyDownloadedArchive(archiveURL: URL, checksumURL: URL, archiveName: String) -> Bool {
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

    private func extractArchive(_ archiveURL: URL, to destinationDir: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", archiveURL.path, "-C", destinationDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            log("failed to launch tar: \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("failed to extract archive: exit=\(proc.terminationStatus), stderr=\(stderr)")
            return false
        }
        return true
    }

    private func downloadAndInstallServer(selection: ReleaseAssetSelection) -> URL? {
        let fm = FileManager.default
        let version = selection.version
        let targetBinary = managedServerBinary(for: version)
        if fm.isExecutableFile(atPath: targetBinary.path), canLaunchServerBinary(targetBinary) {
            return targetBinary
        }
        guard let archiveRemoteURL = URL(string: selection.archive.browser_download_url),
              let checksumAsset = selection.checksum,
              let checksumRemoteURL = URL(string: checksumAsset.browser_download_url)
        else {
            log("invalid asset URL for release \(version)")
            return nil
        }

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

        let archiveURL = stagingRoot.appendingPathComponent(selection.archive.name)
        let checksumURL = stagingRoot.appendingPathComponent(checksumAsset.name)

        log("downloading server \(version) asset \(selection.archive.name)")
        guard downloadFile(from: archiveRemoteURL, to: archiveURL) else {
            return nil
        }
        guard downloadFile(from: checksumRemoteURL, to: checksumURL) else {
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
            log("failed to activate new server \(version): \(error.localizedDescription)")
            return nil
        }

        let finalBinary = finalArchDir.appendingPathComponent(Config.appName)
        guard canLaunchServerBinary(finalBinary) else {
            try? fm.removeItem(at: finalArchDir)
            log("activated server \(version) failed post-install validation")
            return nil
        }
        log("installed server \(version) to \(finalBinary.path)")
        return finalBinary
    }

    private func refreshServerFromGitHub() -> ServerUpdateResult {
        let bundled = bundledVersion()
        _ = installBundledServerIfNeeded(version: bundled)
        let requiredMajor = majorVersion(bundled)
        let current = installedCompatibleVersions(requiredMajor: requiredMajor).first ?? bundled

        guard let latestRelease = fetchLatestRelease() else {
            return .failed
        }
        let latest = latestRelease.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard majorVersion(latest) == requiredMajor else {
            log("latest release \(latest) is incompatible with app major \(requiredMajor), keeping \(current)")
            return .upToDate(version: current)
        }
        if compareVersions(latest, current) != .orderedDescending {
            log("server already up to date at \(current)")
            return .upToDate(version: current)
        }
        guard let selection = selectReleaseAssets(from: latestRelease) else {
            return .unavailable(currentVersion: current, arch: architectureLabel())
        }
        guard downloadAndInstallServer(selection: selection) != nil else {
            return .failed
        }
        return .updated(version: selection.version)
    }

    private func updateServerInBackground(notifyWhenCurrent: Bool) {
        guard !isUpdatingServer else {
            log("server update already in progress")
            return
        }
        isUpdatingServer = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.refreshServerFromGitHub()
            DispatchQueue.main.async {
                self.isUpdatingServer = false
                switch result {
                case .updated(let version):
                    log("server updated to \(version), restarting")
                    self.stopRunningServer()
                    self.startServer(checkForUpdates: false)
                    self.postNotification(title: Config.displayName, body: Config.Notification.serverUpdatedMessage(version))
                case .upToDate(let version):
                    if notifyWhenCurrent {
                        self.postNotification(title: Config.displayName, body: Config.Notification.serverUpToDateMessage(version))
                    }
                case let .unavailable(currentVersion, arch):
                    if notifyWhenCurrent {
                        self.postNotification(
                            title: Config.displayName,
                            body: Config.Notification.serverUnavailableMessage(arch, currentVersion)
                        )
                    }
                case .failed:
                    if notifyWhenCurrent {
                        self.postNotification(title: Config.displayName, body: Config.Notification.serverUpdateFailureMessage)
                    }
                }
            }
        }
    }

    private func launchServerProcess(binary: URL, version: String) {
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

    @objc private func restartServer(_ sender: NSMenuItem) {
        log("restart requested")
        stopRunningServer()
        startServer()
        log("server restarted")
    }

    @objc private func openBindings() {
        guard let url = URL(string: Config.serverURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func updateServer(_ sender: NSMenuItem) {
        log("manual server update requested")
        updateServerInBackground(notifyWhenCurrent: true)
    }

    @objc private func updatePlugins(_ sender: NSMenuItem) {
        guard !isUpdatingPlugins else {
            log("plugin update already in progress")
            return
        }
        isUpdatingPlugins = true
        log("updating plugins...")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = BrewManager.upgradeAll()
            log("plugin update finished, success=\(ok)")
            DispatchQueue.main.async {
                self?.isUpdatingPlugins = false
                self?.postNotification(success: ok)
            }
        }
    }

    private func postNotification(success: Bool) {
        let body = success ? Config.Notification.pluginsUpdatedMessage : Config.Notification.pluginUpdateFailureMessage
        postNotification(title: Config.displayName, body: body)
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: Config.Notification.identifier, content: content, trigger: nil)
        log("posting notification: \(title) – \(body)")
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log("notification error: \(error.localizedDescription)")
            } else {
                log("notification posted ok")
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !isLaunchAtLoginEnabled
        setLaunchAtLogin(enabled: newState)
        sender.state = newState ? .on : .off
    }

    @objc private func quit() {
        stopRunningServer()
        NSApp.terminate(nil)
    }

    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log("failed to set launch at login: \(error)")
            }
        }
    }
}

let app = NSApplication.shared

let bundleID = Bundle.main.bundleIdentifier ?? Config.bundleIdentifier
let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
if running.count > 1 {
    log("another instance already running, exiting")
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
