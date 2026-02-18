import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let serverPort: UInt16 = 8000
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        startServer()
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = loadBunnyIcon()
        }
        
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Open Bindings", action: #selector(openBindings), keyEquivalent: "b"))
        menu.addItem(NSMenuItem.separator())
        
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    private func loadBunnyIcon() -> NSImage {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        
        guard let img1x = loadImageFromResources("bunny", ext: "png"),
              let img2x = loadImageFromResources("bunny@2x", ext: "png") else {
            return createFallbackIcon()
        }
        
        if let rep1x = NSBitmapImageRep(data: img1x.tiffRepresentation!) {
            rep1x.size = NSSize(width: 18, height: 18)
            icon.addRepresentation(rep1x)
        }
        if let rep2x = NSBitmapImageRep(data: img2x.tiffRepresentation!) {
            rep2x.size = NSSize(width: 18, height: 18)
            icon.addRepresentation(rep2x)
        }
        
        icon.isTemplate = true
        return icon
    }
    
    private func loadImageFromResources(_ name: String, ext: String) -> NSImage? {
        guard let path = Bundle.main.path(forResource: name, ofType: ext) else { return nil }
        return NSImage(contentsOfFile: path)
    }
    
    private func createFallbackIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11, y: 11, width: 3, height: 6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 1, width: 14, height: 12)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    
    private func startServer() {
        let port = serverPort
        DispatchQueue.global(qos: .background).async {
            let result = bunnylol_serve(port)
            if result != 0 {
                NSLog("bunnylol server exited with code \(result)")
            }
        }
    }
    
    @objc private func openBindings() {
        let url = URL(string: "http://localhost:\(serverPort)")!
        NSWorkspace.shared.open(url)
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !isLaunchAtLoginEnabled()
        setLaunchAtLogin(enabled: newState)
        sender.state = newState ? .on : .off
    }
    
    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return false
        }
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Failed to set launch at login: \(error)")
            }
        }
    }
    
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
