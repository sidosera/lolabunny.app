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
    lazy var updateSource: any UpdateSource = {
        if Config.Server.updateProvider.caseInsensitiveCompare("GitHub") == .orderedSame {
            guard let org = Config.Server.updateGitHubOrg else {
                log("missing GitHub update org config")
                return DisabledUpdateSource()
            }
            guard let repository = Config.Server.updateGitHubRepository else {
                log("missing GitHub update repository config")
                return DisabledUpdateSource()
            }
            if let source = GitHubUpdateSource(org: org, repository: repository, userAgent: Config.displayName) {
                return source
            }
            log("invalid GitHub update source config: org=\(org), repo=\(repository)")
            return DisabledUpdateSource()
        }
        log("unsupported update provider: \(Config.Server.updateProvider)")
        return DisabledUpdateSource()
    }()
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
