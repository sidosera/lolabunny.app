import AppKit
import ServiceManagement
import SwiftUI

public struct AppView: View {
    @ObservedObject var app: AppDelegate

    public init(app: AppDelegate) {
        self.app = app
    }

    public var body: some View {
        Group {
            serverStatusSection

            Button(Config.Menu.openBindings) {
                app.openBindings()
            }
            .disabled(!app.canOpenBindings)

            Toggle(Config.Menu.launchAtLogin, isOn: Binding(
                get: { app.enableLaunchAtLogin },
                set: { app.setLaunchAtLogin(enabled: $0) }
            ))

            Divider()

            Button(Config.Menu.quit) {
                app.quit()
            }
        }
        .onAppear {
            app.startIfNeeded()
            app.refreshServerSetupUI()
        }
    }

    @ViewBuilder
    private var serverStatusSection: some View {
        switch app.serverSetupState {
        case .GettingReady:
            Text("Locating Server...")
                .foregroundStyle(.secondary)

        case .Ready(let version):
            Text(version)
                .foregroundStyle(.secondary)

        case .Failed:
            Text("Server Failed")
                .foregroundStyle(.secondary)
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

    func setServerSetupState(_ state: ServerSetupState) {
        serverSetupState = state
    }

    func refreshServerSetupUI() {
        let enabled = isLaunchAtLoginEnabled
        if enableLaunchAtLogin != enabled {
            enableLaunchAtLogin = enabled
        }
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

    func quit() {
        serverWatchdogTimer?.invalidate()
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
