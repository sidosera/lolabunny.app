import AppKit
import LolabunnyWidgetCore
import SwiftUI

struct LolabunnyWidget: App {
    @StateObject private var widget: AppDelegate

    init() {
        let model = AppDelegate()
        _widget = StateObject(wrappedValue: model)

        if let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if running.count > 1 {
                log("another instance already running, exiting")
                exit(0)
            }
        } else {
            log("skipping single-instance check – missing bundle identifier (SwiftPM build?)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AppView(widget: widget)
        } label: {
            Image(nsImage: widget.statusBarIcon)
                .opacity(widget.shouldDimStatusBarIcon ? 0.5 : 1.0)
                .onAppear {
                    widget.startIfNeeded()
                }
        }
        .menuBarExtraStyle(.menu)
    }
}

LolabunnyWidget.main()
