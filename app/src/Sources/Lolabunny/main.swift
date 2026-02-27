import Cocoa

let app = NSApplication.shared

let bundleID = Config.bundleIdentifier
let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
if running.count > 1 {
    log("another instance already running, exiting")
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
