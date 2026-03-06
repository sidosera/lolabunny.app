import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, ObservableObject {
    @Published var backendSetupState: BackendSetupState = .starting
    @Published var isApplyingBackendUpdate = false
    @Published var isBootstrappingBackend = false
    @Published var enableLaunchAtLogin = false
    @Published var menuRenderNonce: UInt64 = 0

    private var hasStarted = false
    var isCheckingUpdates = false
    var bootstrapPromptPosted = false
    var allowAutomaticBackendDownloads = false
    var pendingBootstrapBackendRequiredMajor: String?
    var updateState = UpdateState()
    var updateTimer: Timer?
    var backendWatchdogTimer: Timer?
    var backendProcess: Process?
    var isStartingBackend = false
    lazy var statusBarIcon: NSImage = makeStatusBarIcon()
    var managedBackendRoot: URL {
        URL(fileURLWithPath: Config.Backend.installRoot, isDirectory: true)
    }

    func startIfNeeded() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let volumePath = Config.Backend.volumePath ?? "(default)"
        log(
            "app launched, arch=\(architectureLabel()), backendRoot=\(managedBackendRoot.path), volumePath=\(volumePath)"
        )
        refreshBackendSetupUI()
        configureNotificationActions()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
                granted, error in
                log("notification auth: granted=\(granted) error=\(String(describing: error))")
            }
        }
        Task {
            await startBackend()
        }
        scheduleBackendWatchdog()
        scheduleUpdateChecks()
        runUpdateCheck(force: false, notify: false)
    }
}
