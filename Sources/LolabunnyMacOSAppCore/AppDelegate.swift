import ApplicationServices
import AppKit
import UserNotifications

@MainActor
public final class AppDelegate: NSObject, ObservableObject {
    @Published public var serverSetupState: ServerSetupState = .GettingReady
    @Published public var enableLaunchAtLogin = false

    private var hasStarted = false
    let commandPalette = CommandPaletteController()
    private var commandPaletteHotKey: GlobalHotKey?
    var isCheckingUpdates = false
    var serverWatchdogTimer: Timer?
    var isStartingServer = false
    public lazy var statusBarIcon: NSImage = makeStatusBarIcon()

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
            "macOS app launched, arch=\(architectureLabel()), server=\(Config.serverBaseURL.absoluteString), volumePath=\(volumePath)"
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
        }
        scheduleServerWatchdog()
        registerCommandPaletteHotKey()
        TextInterceptor.shared.start()
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
            alert.informativeText = "\(Config.CommandPalette.hotKeyLabel) needs Accessibility permission so \(Config.displayName) can catch the shortcut before the front app handles it."
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
            alert.informativeText = "\(Config.CommandPalette.hotKeyLabel) is already used by macOS or another app. Open Keyboard Shortcuts to remap the conflicting shortcut, then restart \(Config.displayName)."
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
