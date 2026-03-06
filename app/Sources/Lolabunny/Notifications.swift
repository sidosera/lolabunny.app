import UserNotifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    func configureNotificationActions() {
        guard Bundle.main.bundleIdentifier != nil else {
            log("skipping notification setup – no bundle identifier (debug build?)")
            return
        }
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

        let bootstrapDownloadAction = UNNotificationAction(
            identifier: Config.Notification.bootstrapDownloadAction,
            title: "Download",
            options: [.foreground]
        )
        let bootstrapLaterAction = UNNotificationAction(
            identifier: Config.Notification.bootstrapLaterAction,
            title: "Later",
            options: []
        )
        let bootstrapCategory = UNNotificationCategory(
            identifier: Config.Notification.bootstrapPromptCategory,
            actions: [bootstrapDownloadAction, bootstrapLaterAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category, bootstrapCategory])
    }

    func postBackendUpdateReadyNotification(_ version: String) {
        postNotification(
            identifier: Config.Notification.identifier + ".update.\(version)",
            title: Config.displayName,
            body: Config.Notification.backendUpdateReadyMessage(version),
            categoryIdentifier: Config.Notification.updatePromptCategory,
            userInfo: [Config.Notification.backendVersionKey: version]
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
        guard Bundle.main.bundleIdentifier != nil else {
            log("skipping notification post – no bundle identifier")
            return
        }
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log("notification error: \(error.localizedDescription)")
            } else {
                log("notification posted ok")
            }
        }
    }

    func postBootstrapPermissionNotification(requiredMajor: String) {
        postNotification(
            identifier: Config.Notification.identifier + ".bootstrap.\(requiredMajor)",
            title: Config.displayName,
            body: Config.Notification.backendBootstrapPermissionMessage(requiredMajor: requiredMajor),
            categoryIdentifier: Config.Notification.bootstrapPromptCategory,
            userInfo: [Config.Notification.backendRequiredMajorKey: requiredMajor]
        )
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let content = response.notification.request.content
        if content.categoryIdentifier == Config.Notification.updatePromptCategory {
            guard response.actionIdentifier == Config.Notification.applyUpdateAction else {
                return
            }
            guard let version = content.userInfo[Config.Notification.backendVersionKey] as? String else {
                log("missing backend version in update notification payload")
                return
            }
            Task { @MainActor [weak self] in
                self?.applyDownloadedBackendUpdate(version: version)
            }
            return
        }

        if content.categoryIdentifier == Config.Notification.bootstrapPromptCategory {
            guard response.actionIdentifier == Config.Notification.bootstrapDownloadAction else {
                return
            }
            let requiredMajor = content.userInfo[Config.Notification.backendRequiredMajorKey] as? String
            Task { @MainActor [weak self] in
                await self?.beginBootstrapBackendDownload(requiredMajor: requiredMajor)
            }
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
