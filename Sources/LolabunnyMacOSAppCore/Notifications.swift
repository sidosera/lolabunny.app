import UserNotifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    private var canUseUserNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func configureNotificationActions() {
        guard canUseUserNotificationCenter else {
            log("skipping notification setup - unavailable main app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([])
    }

    func postNotification(
        identifier: String = Config.Notification.identifier,
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        guard canUseUserNotificationCenter else {
            log("skipping notification post - unavailable main app bundle: \(title) - \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        log("posting notification: \(title) – \(body)")
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            let message: String
            if let error {
                message = "notification error: \(error.localizedDescription)"
            } else {
                message = "notification posted ok"
            }
            Task { @MainActor in
                log(message)
            }
        }
    }

    public nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    public nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
