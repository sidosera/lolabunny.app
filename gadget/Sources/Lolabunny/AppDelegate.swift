import Cocoa
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var isCheckingUpdates = false
    var isApplyingServerUpdate = false
    var updateState = UpdateState()
    var updateTimer: Timer?
    var serverProcess: Process?
    var bundledServerBinary: URL {
        let executableURL = Bundle.main.executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Config.appName)")
        return executableURL
            .deletingLastPathComponent()
            .appendingPathComponent(Config.appName)
    }

    var managedServerRoot: URL {
        URL(fileURLWithPath: Config.Server.installRoot, isDirectory: true)
    }

    var pendingServerRoot: URL {
        managedServerRoot.appendingPathComponent(".pending", isDirectory: true)
    }

    func applicationDidFinishLaunching(_: Notification) {
        log("app launched, arch=\(architectureLabel()), serverRoot=\(managedServerRoot.path)")
        setupStatusBar()
        configureNotificationActions()
        Task {
            await startServer()
        }
        scheduleUpdateChecks()
        runUpdateCheck(force: false, notify: false)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            log("notification auth: granted=\(granted) error=\(String(describing: error))")
        }
    }
}
