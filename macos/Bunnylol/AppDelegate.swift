import Cocoa
import os.log
import ServiceManagement
import UserNotifications

private let logger = OSLog(subsystem: "com.sidosera.bunnylol", category: "app")

private func log(_ message: String) {
    os_log("%{public}s", log: logger, type: .default, message)
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    let logPath = NSHomeDirectory() + "/Library/Logs/bunnylol.log"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

private enum Config {
    static let serverPort: UInt16 = 8085
    static let iconSize = NSSize(width: 18, height: 18)
    enum Brew {
        #if arch(arm64)
        static let prefix = "/opt/homebrew"
        #else
        static let prefix = "/usr/local"
        #endif
        static let executable = prefix + "/bin/brew"
        static let pluginDir  = prefix + "/share/bunnylol/commands"
    }
}

private enum BrewManager {
    /// Each subdirectory under the plugin dir is named after its Homebrew formula.
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
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.contains(brewBin) {
            env["PATH"] = brewBin + ":" + path
        }
        return env
    }
}

// MARK: - App Delegate

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

        menu.addItem(NSMenuItem(title: "Open Bindings", action: #selector(openBindings), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Update", action: #selector(updatePlugins), keyEquivalent: "u"))
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    private func makeStatusBarIcon() -> NSImage {
        let icon = NSImage(size: Config.iconSize)
        let variants = ["bunny", "bunny@2x"]
        var loaded = false

        for name in variants {
            guard let path = Bundle.main.path(forResource: name, ofType: "png"),
                  let img = NSImage(contentsOfFile: path),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
            else { continue }
            rep.size = Config.iconSize
            icon.addRepresentation(rep)
            loaded = true
        }

        guard loaded else { return makeFallbackIcon() }
        icon.isTemplate = true
        return icon
    }

    private func makeFallbackIcon() -> NSImage {
        let image = NSImage(size: Config.iconSize, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 1, width: 14, height: 12)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func startServer() {
        let port = Config.serverPort
        DispatchQueue.global(qos: .background).async {
            let result = bunnylol_serve(port)
            if result != 0 {
                log("server exited with code \(result)")
            }
        }
    }

    // Actions

    @objc private func openBindings() {
        guard let url = URL(string: "http://localhost:\(Config.serverPort)") else { return }
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
        let content = UNMutableNotificationContent()
        content.title = "Bunnylol"
        content.body = success ? "Plugins updated." : "Plugin update failed."
        let request = UNNotificationRequest(identifier: "plugin-update", content: content, trigger: nil)
        log("posting notification, success=\(success)")
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

// Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
