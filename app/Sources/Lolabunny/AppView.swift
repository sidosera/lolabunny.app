import AppKit
import ServiceManagement
import SwiftUI


private func menuItemText(_ icon: String, _ title: String) -> Text {
    Text(Image(systemName: icon)).font(.system(size: 11)) + Text(" \(title)")
}

private func menuItemText(_ title: String) -> Text {
    Text(Image(systemName: "checkmark")).font(.system(size: 11)).foregroundColor(.clear) + Text(" \(title)")
}

struct AppView: View {
    @ObservedObject var app: AppDelegate

    private var latestVersion: String? {
        app.availableBackendUpdateVersionForMenu
    }

    var body: some View {
        Group {
            backendStatusSection

            if let latestVersion {
                Button(action: {
                    app.applyDownloadedBackendUpdate(version: latestVersion)
                }) {
                    menuItemText("arrow.down.circle", app.updateMenuVersionText(updateVersion: latestVersion))
                }
                .disabled(app.isApplyingBackendUpdate)

            }

            Button(action: { app.openBindings() }) {
                menuItemText(Config.Menu.openBindings)
            }
            .disabled(!app.canOpenBindings)

            Button(action: {
                app.setLaunchAtLogin(enabled: !app.enableLaunchAtLogin)
            }) {
                if app.enableLaunchAtLogin {
                    menuItemText("checkmark", Config.Menu.launchAtLogin)
                } else {
                    menuItemText(Config.Menu.launchAtLogin)
                }
            }

            Divider()

            Button(action: { app.quit() }) {
                menuItemText(Config.Menu.quit)
            }
        }
        .onAppear {
            app.startIfNeeded()
            app.refreshBackendSetupUI()
        }
    }

    @ViewBuilder
    private var backendStatusSection: some View {
        switch app.backendSetupState {
        case .starting:
            menuItemText("shippingbox", "Looking for backend...")
                .foregroundStyle(.secondary)
        case .waitingForDownloadPermission:
            Button(action: { app.downloadBackendNow() }) {
                menuItemText("arrow.down.to.line", "Download backend")
            }
            .disabled(app.isBootstrappingBackend)
        case .downloading(let phase, let progress):
            InflightDownloadOfBackendView(phase: phase, progress: progress)
        case .ready(let version):
            menuItemText("shippingbox", version.trimmingCharacters(in: .whitespacesAndNewlines))
        case .blocked(let message):
            Button(action: { app.downloadBackendNow() }) {
                menuItemText("arrow.clockwise", "Retry Download")
            }
            .disabled(app.isBootstrappingBackend)
            .help(message)
        }
    }
}

private struct InflightDownloadOfBackendView: View {
    let phase: String
    let progress: Double

    var body: some View {
        let clamped = max(0.0, min(progress, 1.0))
        let percent = Int((clamped * 100.0).rounded())
        VStack(alignment: .leading, spacing: 5) {
            menuItemText("shippingbox", "\(phase) (\(percent)%)")
                .foregroundStyle(.secondary)
            ProgressView(value: clamped)
        }
    }
}


extension AppDelegate {

    var canOpenBindings: Bool {
        if case .ready = backendSetupState {
            return true
        }
        return false
    }

    var availableBackendUpdateVersionForMenu: String? {
        guard case .ready(let version) = backendSetupState else {
            return nil
        }
        let current = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return availableBackendUpdateVersion(currentVersion: current)
    }

    func setBackendSetupState(_ state: BackendSetupState) {
        backendSetupState = state
        refreshBackendSetupUI()
    }

    func refreshBackendSetupUI() {
        enableLaunchAtLogin = isLaunchAtLoginEnabled
        menuRenderNonce &+= 1
    }

    func updateMenuVersionText(updateVersion: String) -> String {
        "Update Now \(compactMenuVersion(updateVersion))"
    }

    func compactMenuVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = parseSemVer(trimmed) {
            if parsed.patch == 0 {
                return "v\(parsed.major).\(parsed.minor)"
            }
            return "v\(parsed.major).\(parsed.minor).\(parsed.patch)"
        }
        return trimmed
    }

    func makeStatusBarIcon() -> NSImage {
        let icon = NSImage(size: Config.Icon.size)
        var loaded = false
        let bundles = [Bundle.main, Bundle.module]

        for name in Config.Icon.variants {
            for bundle in bundles {
                guard let path = bundle.path(forResource: name, ofType: Config.Icon.fileType),
                    let img = NSImage(contentsOfFile: path),
                    let tiff = img.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff)
                else { continue }
                rep.size = Config.Icon.size
                icon.addRepresentation(rep)
                loaded = true
                break
            }
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

    func openBindings() {
        NSWorkspace.shared.open(Config.backendBaseURL)
    }

    func downloadBackendNow() {
        guard !isBootstrappingBackend else {
            return
        }
        // Update menu state immediately so users see progress right after click.
        setBackendSetupState(.downloading(phase: "Preparing", progress: 0.01))
        Task { @MainActor [weak self] in
            await self?.beginBootstrapBackendDownload(requiredMajor: nil)
        }
    }

    func quit() {
        backendWatchdogTimer?.invalidate()
        updateTimer?.invalidate()
        stopRunningBackend()
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
        refreshBackendSetupUI()
    }
}
