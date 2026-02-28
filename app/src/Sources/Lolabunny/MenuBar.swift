import Cocoa
import ServiceManagement

extension AppDelegate {
    func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusBarIcon()
        item.button?.title = ""
        item.menu = buildMenu()
        statusItem = item
        refreshServerSetupUI()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let serverCardItem = makeServerCardMenuItem()
        menu.addItem(serverCardItem)
        statusMenuServerCardItem = serverCardItem

        menu.addItem(.separator())

        let bindingsItem = NSMenuItem(title: Config.Menu.openBindings, action: #selector(openBindings), keyEquivalent: "b")
        bindingsItem.target = self
        menu.addItem(bindingsItem)
        openBindingsMenuItem = bindingsItem
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: Config.Menu.launchAtLogin,
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: Config.Menu.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func makeServerCardMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
        item.isEnabled = false

        let width: CGFloat = 238
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        let indicator = NSProgressIndicator(frame: NSRect(x: 18, y: 5, width: width - 36, height: 10))
        indicator.style = .bar
        indicator.controlSize = .small
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = 0

        container.addSubview(indicator)
        statusMenuServerProgressView = container
        statusMenuServerProgressIndicator = indicator

        return item
    }

    func setServerSetupState(_ state: ServerSetupState) {
        serverSetupState = state
        refreshServerSetupUI()
    }

    func refreshServerSetupUI() {
        let button = statusItem?.button
        let serverItem = statusMenuServerCardItem
        switch serverSetupState {
        case .starting:
            serverItem?.view = nil
            serverItem?.title = "Starting..."
            serverItem?.action = nil
            serverItem?.target = nil
            serverItem?.isEnabled = false
            openBindingsMenuItem?.isEnabled = false
            button?.alphaValue = 0.7
            button?.toolTip = "Lolabunny is starting"
            button?.title = ""
        case let .waitingForDownloadPermission(requiredMajor):
            _ = requiredMajor
            serverItem?.view = nil
            serverItem?.title = "Download server"
            serverItem?.action = #selector(downloadServerNow)
            serverItem?.target = self
            serverItem?.isEnabled = true
            openBindingsMenuItem?.isEnabled = false
            button?.alphaValue = 0.7
            button?.toolTip = "Lolabunny is waiting for server download permission"
            button?.title = ""
        case let .downloading(phase, progress):
            let clamped = max(0.0, min(progress, 1.0))
            let percent = Int((clamped * 100.0).rounded())
            serverItem?.view = statusMenuServerProgressView
            serverItem?.action = nil
            serverItem?.target = nil
            serverItem?.isEnabled = false
            statusMenuServerProgressIndicator?.doubleValue = clamped
            openBindingsMenuItem?.isEnabled = false
            button?.alphaValue = 0.7
            button?.toolTip = "Lolabunny: \(phase) (\(percent)%)"
            button?.title = ""
        case let .ready(version):
            serverItem?.view = nil
            serverItem?.title = version
            serverItem?.action = nil
            serverItem?.target = nil
            serverItem?.isEnabled = false
            openBindingsMenuItem?.isEnabled = true
            button?.alphaValue = 1.0
            button?.toolTip = "Lolabunny is ready"
            button?.title = ""
        case let .blocked(message):
            serverItem?.view = nil
            serverItem?.title = "Download server"
            serverItem?.action = #selector(downloadServerNow)
            serverItem?.target = self
            serverItem?.isEnabled = !isBootstrappingServer
            openBindingsMenuItem?.isEnabled = false
            button?.alphaValue = 0.7
            button?.toolTip = "Lolabunny server unavailable: \(message)"
            button?.title = ""
        }
    }

    func makeStatusBarIcon() -> NSImage {
        let icon = NSImage(size: Config.Icon.size)
        var loaded = false

        for name in Config.Icon.variants {
            guard let path = Bundle.main.path(forResource: name, ofType: Config.Icon.fileType),
                  let img = NSImage(contentsOfFile: path),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
            else { continue }
            rep.size = Config.Icon.size
            icon.addRepresentation(rep)
            loaded = true
        }

        guard loaded else { return makeFallbackIcon() }
        icon.isTemplate = true
        return icon
    }

    func makeFallbackIcon() -> NSImage {
        let image = NSImage(size: Config.Icon.size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 1, width: 14, height: 12)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc func openBindings() {
        NSWorkspace.shared.open(Config.serverBaseURL)
    }

    @objc func downloadServerNow() {
        Task { @MainActor [weak self] in
            await self?.beginBootstrapDownload(requiredMajor: nil)
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !isLaunchAtLoginEnabled
        setLaunchAtLogin(enabled: newState)
        sender.state = newState ? .on : .off
    }

    @objc func quit() {
        stopRunningServer()
        NSApp.terminate(nil)
    }

    var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log("failed to set launch at login: \(error)")
            }
        }
    }
}
