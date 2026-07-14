import Darwin
import LolabunnyMacOSAppCore
import LolabunnyServerCore
import SwiftUI

@main
struct LolabunnyMacOSApp: App {
    @StateObject private var app: AppDelegate

    init() {
        EmbeddedServer.shared.start()

        let model = AppDelegate()
        _app = StateObject(wrappedValue: model)
        enforceSingleLolabunnyInstance(label: "macOS app")
    }

    var body: some Scene {
        LolabunnyMenuBarScene(app: app)
    }
}

private final class EmbeddedServer: @unchecked Sendable {
    static let shared = EmbeddedServer()

    private let queue = DispatchQueue(label: "lolabunny.embedded-lolabunny-server", qos: .userInitiated)
    private var started = false

    private init() {}

    func start() {
        guard !started else {
            return
        }
        started = true

        signal(SIGPIPE, SIG_IGN)

        let address = bundleString("LolabunnyServerAddress") ?? "127.0.0.1"
        let port = UInt16(bundleString("LolabunnyServerPort") ?? "") ?? 8_085
        let version = Paths.versionString()

        setenv("LOLABUNNY_SERVER_ADDRESS", address, 1)
        setenv("LOLABUNNY_SERVER_PORT", "\(port)", 1)
        setenv("LOLABUNNY_SERVER_VERSION", version, 1)

        queue.async {
            var config = AppConfig()
            config.server.address = address
            config.server.port = port
            config.server.logLevel = bundleString("LolabunnyServerLogLevel") ?? "normal"
            config.server.volumePath = bundleString("LolabunnyVolumePath")
            config.defaultSearch = bundleString("LolabunnyDefaultSearch") ?? "google"
            config.history.enabled = bundleBool("LolabunnyHistoryEnabled") ?? true
            config.history.maxEntries = Int(bundleString("LolabunnyHistoryMaxEntries") ?? "") ?? 1_000

            do {
                let server = HTTPServer(
                    address: address,
                    port: port,
                    router: CommandRouter(),
                    config: config
                )
                try server.run()
            } catch {
                log("embedded lolabunny-server failed: \(error.localizedDescription)")
            }
        }
    }
}

private func bundleString(_ key: String) -> String? {
    if let value = ProcessInfo.processInfo.environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
    }
    if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
    }
    return nil
}

private func bundleBool(_ key: String) -> Bool? {
    guard let raw = bundleString(key)?.lowercased() else {
        return nil
    }
    switch raw {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return nil
    }
}
