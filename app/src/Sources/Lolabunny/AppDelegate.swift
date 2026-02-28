import Cocoa
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var statusMenuServerCardItem: NSMenuItem?
    var statusMenuServerProgressView: NSView?
    var statusMenuServerProgressIndicator: NSProgressIndicator?
    var openBindingsMenuItem: NSMenuItem?
    var isCheckingUpdates = false
    var isApplyingServerUpdate = false
    var isBootstrappingServer = false
    var bootstrapPromptPosted = false
    var allowAutomaticServerDownloads = false
    var pendingBootstrapRequiredMajor: String?
    var serverSetupState: ServerSetupState = .starting
    var updateState = UpdateState()
    var updateTimer: Timer?
    var serverProcess: Process?
    lazy var updateService: any UpdateService = {
        guard let provider = Config.Server.updateProvider else {
            log("missing update provider config")
            return DisabledUpdateService()
        }
        guard provider.caseInsensitiveCompare("GitHubGist") == .orderedSame else {
            log("unsupported update provider: \(provider)")
            return DisabledUpdateService()
        }
        guard let gistID = Config.Server.updateGitHubGistID else {
            log("missing GitHubGist update gist ID config")
            return DisabledUpdateService()
        }
        guard let manifestFileName = Config.Server.updateGitHubGistManifestFile else {
            log("missing GitHubGist update manifest file config")
            return DisabledUpdateService()
        }
        if let service = GistUpdateService(
            gistID: gistID,
            manifestFileName: manifestFileName,
            userAgent: Config.displayName
        ) {
            return service
        }
        log("invalid GitHubGist update service config: gistID=\(gistID), manifest=\(manifestFileName)")
        return DisabledUpdateService()
    }()
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            log("notification auth: granted=\(granted) error=\(String(describing: error))")
        }
        Task {
            await startServer()
        }
        scheduleUpdateChecks()
        runUpdateCheck(force: false, notify: false)
    }
}
