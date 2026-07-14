import AppKit
import SwiftUI

public struct LolabunnyMenuBarScene: Scene {
    @ObservedObject private var app: AppDelegate

    public init(app: AppDelegate) {
        self.app = app
    }

    public var body: some Scene {
        MenuBarExtra {
            AppView(app: app)
        } label: {
            Image(nsImage: app.statusBarIcon)
                .opacity(app.shouldDimStatusBarIcon ? 0.5 : 1.0)
                .onAppear {
                    app.startIfNeeded()
                }
        }
        .menuBarExtraStyle(.menu)
    }
}

public func enforceSingleLolabunnyInstance(label: String = "instance") {
    guard let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
          !bundleID.isEmpty
    else {
        log("skipping single-instance check - missing bundle identifier")
        return
    }

    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if running.count > 1 {
        log("another \(label) already running, exiting")
        exit(0)
    }
}
