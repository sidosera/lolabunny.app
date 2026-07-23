import AppKit
import UserNotifications

@MainActor
public final class AppDelegate: NSObject, ObservableObject {
    @Published public var serverSetupState: ServerSetupState = .GettingReady
    @Published public var enableLaunchAtLogin = false

    private var hasStarted = false
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
    }
}
