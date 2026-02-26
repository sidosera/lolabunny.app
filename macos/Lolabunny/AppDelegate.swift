import Cocoa
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
        static let update         = "Update"
        static let launchAtLogin  = "Launch at Login"
        static let quit           = "Quit"
    }

    enum Notification {
        static let identifier     = "plugin-update"
        static let successMessage = "Plugins updated."
        static let failureMessage = "Plugin update failed."
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
    private var isUpdating = false

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(updatePlugins(_:)) {
            return !isUpdating
        }
        return true
    }

    func applicationDidFinishLaunching(_: Notification) {
        log("app launched, pluginDir=\(Config.Brew.pluginDir)")
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
        menu.addItem(NSMenuItem(title: Config.Menu.update, action: #selector(updatePlugins), keyEquivalent: "u"))
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

    private var serverBinary: URL {
        if let path = resolveFromPATH(Config.appName) {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent(Config.appName)
    }

    private func resolveFromPATH(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let brewBin = Config.Brew.prefix + "/bin"
        let searchPaths = paths.contains(brewBin) ? paths : [brewBin] + paths
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = dir + "/" + name
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func startServer() {
        if let pid = readPidFile(), isProcessRunning(pid) {
            if let runningVersion = probeRunningServer(),
               isMajorCompatible(running: runningVersion, bundled: bundledVersion()) {
                log("compatible server already running (pid=\(pid), version=\(runningVersion))")
                return
            }
            log("incompatible server at pid=\(pid), bundled=\(bundledVersion())")
            postNotification(
                title: "Server Update Required",
                body: "Running server is incompatible with app \(bundledVersion()). Use Restart Server."
            )
            return
        }
        launchServerProcess()
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

    private func isMajorCompatible(running: String, bundled: String) -> Bool {
        majorVersion(running) == majorVersion(bundled)
    }

    private func majorVersion(_ version: String) -> String {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return String(v.prefix(while: { $0 != "." }))
    }

    private func launchServerProcess() {
        guard FileManager.default.isExecutableFile(atPath: serverBinary.path) else {
            log("server binary not found at \(serverBinary.path)")
            return
        }

        let proc = Process()
        proc.executableURL = serverBinary
        proc.arguments = ["serve", "--port", "\(Config.serverPort)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            log("server exited with code \(p.terminationStatus)")
        }
        do {
            try proc.run()
            serverProcess = proc
            log("server started, pid=\(proc.processIdentifier), binary=\(serverBinary.path)")
        } catch {
            log("failed to start server: \(error.localizedDescription)")
        }
    }

    @objc private func restartServer(_ sender: NSMenuItem) {
        log("restart requested")
        stopRunningServer()
        launchServerProcess()
        log("server restarted")
    }

    @objc private func openBindings() {
        guard let url = URL(string: Config.serverURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func updatePlugins(_ sender: NSMenuItem) {
        guard !isUpdating else {
            log("update already in progress")
            return
        }
        isUpdating = true
        log("updating plugins...")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = BrewManager.upgradeAll()
            log("update finished, success=\(ok)")
            DispatchQueue.main.async {
                self?.isUpdating = false
                self?.postNotification(success: ok)
            }
        }
    }

    private func postNotification(success: Bool) {
        let body = success ? Config.Notification.successMessage : Config.Notification.failureMessage
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
