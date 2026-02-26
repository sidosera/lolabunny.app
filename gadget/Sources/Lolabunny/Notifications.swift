import UserNotifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    func configureNotificationActions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let applyAction = UNNotificationAction(
            identifier: Config.Notification.applyUpdateAction,
            title: "Update",
            options: [.foreground]
        )
        let deferAction = UNNotificationAction(
            identifier: Config.Notification.deferUpdateAction,
            title: "Later",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Config.Notification.updatePromptCategory,
            actions: [applyAction, deferAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func postUpdateReadyNotification(_ version: String) {
        postNotification(
            identifier: Config.Notification.identifier + ".update.\(version)",
            title: Config.displayName,
            body: Config.Notification.serverUpdateReadyMessage(version),
            categoryIdentifier: Config.Notification.updatePromptCategory,
            userInfo: [Config.Notification.serverVersionKey: version]
        )
    }

    func postNotification(
        identifier: String = Config.Notification.identifier,
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) {
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
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log("notification error: \(error.localizedDescription)")
            } else {
                log("notification posted ok")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let content = response.notification.request.content
        guard content.categoryIdentifier == Config.Notification.updatePromptCategory else {
            return
        }
        guard response.actionIdentifier == Config.Notification.applyUpdateAction else {
            return
        }
        guard let version = content.userInfo[Config.Notification.serverVersionKey] as? String else {
            log("missing server version in update notification payload")
            return
        }
        Task { @MainActor [weak self] in
            self?.applyDownloadedServerUpdate(version: version)
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
