import AppKit
import ServiceManagement
import SwiftUI

public struct AppView: View {
    @ObservedObject var widget: AppDelegate
    @ObservedObject private var interceptor = TextInterceptor.shared

    public init(widget: AppDelegate) {
        self.widget = widget
    }

    public var body: some View {
        Group {
            serverStatusSection

            if let version = widget.availableServerUpdateVersionForMenu {
                Button(widget.updateMenuVersionText(updateVersion: version)) {
                    widget.applyDownloadedServerUpdate(version: version)
                }
                .disabled(widget.isApplyingServerUpdate)
            }

            Button(Config.Menu.openBindings) {
                widget.openBindings()
            }
            .disabled(!widget.canOpenBindings)

            Button("\(Config.Menu.openSearch)  \(Config.CommandPalette.hotKeyLabel)") {
                widget.openCommandPalette()
            }

            Toggle(Config.Menu.launchAtLogin, isOn: Binding(
                get: { widget.enableLaunchAtLogin },
                set: { widget.setLaunchAtLogin(enabled: $0) }
            ))

            Divider()

            interceptorSection

            Divider()

            Button(Config.Menu.quit) {
                widget.quit()
            }
        }
        .onAppear {
            widget.startIfNeeded()
            widget.refreshServerSetupUI()
            interceptor.refreshPermissionStatus()
        }
    }

    @ViewBuilder
    private var interceptorSection: some View {
        Toggle("Text Interceptor  ⇧⌘L", isOn: Binding(
            get: { interceptor.isEnabled },
            set: { interceptor.isEnabled = $0 }
        ))

        if !interceptor.accessibilityGranted {
            Button("Grant Accessibility Access") {
                interceptor.requestAccessibilityPermission()
            }
        }
    }

    @ViewBuilder
    private var serverStatusSection: some View {
        switch widget.serverSetupState {
        case .GettingReady:
            Text("Locating Server...")
                .foregroundStyle(.secondary)

        case .WaitForDownloadPermission:
            Button("Download Server") {
                widget.downloadServerNow()
            }
            .disabled(widget.isBootstrappingServer)

        case .DownloadInflight(_, let progress):
            Text("Downloading \(Int(progress * 100))%")
                .foregroundStyle(.secondary)

        case .Ready(let version):
            Text(version)
                .foregroundStyle(.secondary)

        case .Failed(let message):
            if widget.isServerStartFailure(message) {
                Text("Server Failed")
                    .foregroundStyle(.secondary)
            } else {
                Button("Retry Download") {
                    widget.downloadServerNow()
                }
                .disabled(widget.isBootstrappingServer)
            }
        }
    }
}

extension AppDelegate {
    public var shouldDimStatusBarIcon: Bool {
        if case .Ready = serverSetupState {
            return false
        }
        return true
    }

    var canOpenBindings: Bool {
        if case .Ready = serverSetupState {
            return true
        }
        return false
    }

    var availableServerUpdateVersionForMenu: String? {
        guard case .Ready(let version) = serverSetupState else {
            return nil
        }
        return availableServerUpdateVersion(
            currentVersion: version.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func setServerSetupState(_ state: ServerSetupState) {
        serverSetupState = state
    }

    func refreshServerSetupUI() {
        let enabled = isLaunchAtLoginEnabled
        if enableLaunchAtLogin != enabled {
            enableLaunchAtLogin = enabled
        }
    }

    func updateMenuVersionText(updateVersion: String) -> String {
        "Update Now \(compactMenuVersion(updateVersion))"
    }

    func compactMenuVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsed = parseSemVer(trimmed) else {
            return trimmed
        }

        if parsed.patch == 0 {
            return "v\(parsed.major).\(parsed.minor)"
        }

        return "v\(parsed.major).\(parsed.minor).\(parsed.patch)"
    }

    func makeStatusBarIcon() -> NSImage {
        let icon = NSImage(size: Config.Icon.size)
        let bundles = [Bundle.module, Bundle.main]

        for name in Config.Icon.variants {
            for bundle in bundles {
                guard
                    let path = bundle.path(forResource: name, ofType: Config.Icon.fileType),
                    let image = NSImage(contentsOfFile: path),
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff)
                else {
                    continue
                }

                rep.size = Config.Icon.size
                icon.addRepresentation(rep)
                icon.isTemplate = true
                return icon
            }
        }

        return makeFallbackIcon()
    }

    func makeFallbackIcon() -> NSImage {
        let image = NSImage(
            systemSymbolName: "shippingbox",
            accessibilityDescription: nil
        ) ?? NSImage(size: Config.Icon.size)

        image.size = Config.Icon.size
        image.isTemplate = true
        return image
    }

    func openBindings() {
        NSWorkspace.shared.open(Config.serverBaseURL)
    }

    func downloadServerNow() {
        guard !isBootstrappingServer else {
            return
        }

        setServerSetupState(.DownloadInflight(phase: "Preparing", progress: 0.01))

        Task { @MainActor [weak self] in
            await self?.beginBootstrapServerDownload(requiredMajor: nil)
        }
    }

    func isServerStartFailure(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalized == "launch failed"
            || normalized == "start failed"
            || normalized.contains("failed to start")
    }

    func quit() {
        serverWatchdogTimer?.invalidate()
        updateTimer?.invalidate()
        stopRunningServer()
        NSApp.terminate(nil)
    }

    var isLaunchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            refreshServerSetupUI()
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("failed to set launch at login: \(error)")
        }

        refreshServerSetupUI()
    }
}
