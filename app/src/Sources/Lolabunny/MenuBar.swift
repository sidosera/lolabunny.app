import Cocoa
import ServiceManagement

extension AppDelegate {
    func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusBarIcon()
        item.menu = buildMenu()
        statusItem = item
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: Config.Menu.openBindings, action: #selector(openBindings), keyEquivalent: "b"))
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: Config.Menu.launchAtLogin,
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Config.Menu.quit, action: #selector(quit), keyEquivalent: "q"))

        return menu
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
