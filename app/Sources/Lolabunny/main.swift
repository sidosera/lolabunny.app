import AppKit
import SwiftUI

struct LolabunnyApp: App {
    @StateObject private var app: AppDelegate

    init() {
        let model = AppDelegate()
        _app = StateObject(wrappedValue: model)

        let bundleID = Config.bundleIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            log("another instance already running, exiting")
            exit(0)
        }

        model.startIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            AppView(app: app)
        } label: {
            Image(nsImage: app.statusBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

LolabunnyApp.main()
