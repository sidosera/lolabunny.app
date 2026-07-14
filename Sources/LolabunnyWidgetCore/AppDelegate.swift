import ApplicationServices
import AppKit
import Combine
import UserNotifications

@MainActor
public final class AppDelegate: NSObject, ObservableObject {
    @Published public var serverSetupState: ServerSetupState = .GettingReady
    @Published public var isApplyingServerUpdate = false
    @Published public var isBootstrappingServer = false
    @Published public var enableLaunchAtLogin = false

    private var hasStarted = false
    let commandPalette = CommandPaletteController()
    private var commandPaletteHotKey: GlobalHotKey?
    var isCheckingUpdates = false
    var bootstrapPromptPosted = false
    var pendingBootstrapServerRequiredMajor: String?
    var updateState = UpdateState()
    var updateTimer: Timer?
    var serverWatchdogTimer: Timer?
    var serverProcess: Process?
    var isStartingServer = false
    var lastServerLaunchAttemptVersion: String?
    public lazy var statusBarIcon: NSImage = makeStatusBarIcon()
    var managedServerRoot: URL {
        URL(fileURLWithPath: Config.Server.installRoot, isDirectory: true)
    }

    public override init() {
        super.init()
    }

    public func startIfNeeded() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let volumePath = Config.Server.volumePath ?? "(default)"
        log(
            "widget launched, arch=\(architectureLabel()), serverRoot=\(managedServerRoot.path), volumePath=\(volumePath)"
        )
        refreshServerSetupUI()
        configureNotificationActions()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
                granted, error in
                log("notification auth: granted=\(granted) error=\(String(describing: error))")
            }
        }
        Task {
            await startServer()
            startServerUpdateChecksIfConfigured()
        }
        scheduleServerWatchdog()
        registerCommandPaletteHotKey()
        TextInterceptor.shared.start()
    }

    private func startServerUpdateChecksIfConfigured() {
        if isServerUpdateSourceConfigured() {
            scheduleUpdateChecks()
            runUpdateCheck(force: false, notify: false)
        } else {
            log("widget-server update checks disabled: update source is not configured")
        }
    }

    func openCommandPalette() {
        commandPalette.show()
    }

    private func registerCommandPaletteHotKey() {
        guard commandPaletteHotKey == nil else {
            return
        }
        let hotKey = GlobalHotKey.commandP { [weak self] in
            self?.commandPalette.toggle()
        }
        let status = hotKey.register()
        if status == noErr {
            commandPaletteHotKey = hotKey
        } else if !AXIsProcessTrusted() {
            showCommandPaletteAccessibilityPrompt()
        } else {
            showCommandPaletteHotKeyConflict(status: status)
        }
    }

    private func showCommandPaletteAccessibilityPrompt() {
        log("command palette hotkey requires accessibility permission")

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enable Accessibility for \(Config.displayName)"
            alert.informativeText = "\(Config.CommandPalette.hotKeyLabel) needs Accessibility permission so \(Config.displayName) can catch the shortcut before the front widget handles it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Dismiss")

            if alert.runModal() == .alertFirstButtonReturn {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                self.openAccessibilitySettings()
            }
        }
    }

    private func showCommandPaletteHotKeyConflict(status: OSStatus) {
        log("command palette hotkey unavailable \(Config.CommandPalette.hotKeyLabel), status=\(status)")

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Command Palette Shortcut Unavailable"
            alert.informativeText = "\(Config.CommandPalette.hotKeyLabel) is already used by macOS or another widget. Open Keyboard Shortcuts to remap the conflicting shortcut, then restart \(Config.displayName)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Keyboard Shortcuts")
            alert.addButton(withTitle: "Dismiss")

            if alert.runModal() == .alertFirstButtonReturn {
                self.openKeyboardShortcutsSettings()
            }
        }
    }

    private func openKeyboardShortcutsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else {
                continue
            }
            return
        }
    }

    private func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else {
                continue
            }
            return
        }
    }
}
