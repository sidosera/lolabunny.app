import Cocoa
import XDG

enum Config {
    static let bundleIdentifier = Config.runtimeString(
        envKey: "LOLABUNNY_BUNDLE_IDENTIFIER",
        plistKeys: ["LolabunnyBundleIdentifier", "CFBundleIdentifier"]
    ) ?? ProcessInfo.processInfo.processName
    static let appName = "lolabunny"
    static let displayName = "Lolabunny"
    static let serverPort: UInt16 = 8085
    static let serverBaseURL = URL(string: "http://localhost:\(serverPort)")!
    static func runtimeString(envKey: String, plistKey: String) -> String? {
        runtimeString(envKey: envKey, plistKeys: [plistKey])
    }

    static func runtimeString(envKey: String, plistKeys: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env[envKey] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        for plistKey in plistKeys {
            if let raw = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    enum Icon {
        static let size = NSSize(width: 18, height: 18)
        static let variants = ["bunny", "bunny@2x"]
        static let fileType = "png"
    }

    enum Log {
        static let path = NSHomeDirectory() + "/Library/Logs/\(Config.appName).log"
    }

    enum Server {
        static let runtimeDir = NSTemporaryDirectory() + ".lolabunny"
        static let pidFile = runtimeDir + "/pid"
        static let downloadChunkDelayMillis: UInt64 = {
            if let raw = Config.runtimeString(
                envKey: "LOLABUNNY_DOWNLOAD_CHUNK_DELAY_MS",
                plistKey: "LolabunnyDownloadChunkDelayMs"
            ),
                let value = UInt64(raw)
            {
                return value
            }
            // Keep progress visible during local UX iteration.
            return 120
        }()
        static let updateProvider = Config.runtimeString(
            envKey: "LOLABUNNY_UPDATE_PROVIDER",
            plistKey: "LolabunnyUpdateProvider"
        )
        static let updateGitHubGistID = Config.runtimeString(
            envKey: "LOLABUNNY_UPDATE_PROVIDER_GITHUB_GIST_ID",
            plistKey: "LolabunnyUpdateProvider.GitHubGist.GistID"
        )
        static let updateGitHubGistManifestFile = Config.runtimeString(
            envKey: "LOLABUNNY_UPDATE_PROVIDER_GITHUB_GIST_MANIFEST_FILE",
            plistKey: "LolabunnyUpdateProvider.GitHubGist.ManifestFile"
        )
        static let autoCheckInterval: TimeInterval = 24 * 60 * 60
        static let schedulerTickInterval: TimeInterval = 60 * 60
        static let dataRoot: String = {
            if let dirs = try? BaseDirectories(prefixAll: ".lolabunny") {
                return dirs.dataHomePrefixed.string
            }
            return NSHomeDirectory() + "/.local/share/.lolabunny"
        }()
        static let installRoot = dataRoot + "/servers"
        static let version: String = {
            guard let path = Bundle.main.path(forResource: ".version", ofType: nil),
                  let contents = try? String(contentsOfFile: path, encoding: .utf8)
            else {
                return "unknown"
            }
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
    }

    enum Menu {
        static let openBindings = "Open Bindings"
        static let launchAtLogin = "Launch at Login"
        static let quit = "Quit"
    }

    enum Notification {
        static let identifier = "lolabunny-notification"
        static let updatePromptCategory = "lolabunny-server-update-prompt"
        static let bootstrapPromptCategory = "lolabunny-server-bootstrap-prompt"
        static let applyUpdateAction = "lolabunny-server-update-apply"
        static let deferUpdateAction = "lolabunny-server-update-later"
        static let bootstrapDownloadAction = "lolabunny-server-bootstrap-download"
        static let bootstrapLaterAction = "lolabunny-server-bootstrap-later"
        static let serverVersionKey = "server_version"
        static let serverRequiredMajorKey = "server_required_major"
        static let updatesCheckFailedMessage = "Update check failed."
        static let noUpdatesMessage = "No updates available."
        static let serverUpdateApplyFailedMessage = "Could not apply downloaded server update."
        static let serverBootstrapFailedMessage = "Could not download a compatible server."

        static func serverUpdateReadyMessage(_ version: String) -> String {
            "Server update \(version) downloaded. Update now?"
        }

        static func serverUpdatedMessage(_ version: String) -> String {
            "Server updated to \(version)."
        }

        static func serverBootstrapPermissionMessage(requiredMajor: String) -> String {
            let major = requiredMajor.trimmingCharacters(in: .whitespacesAndNewlines)
            if major.isEmpty {
                return "Download compatible server now?"
            }
            return "Download compatible server major \(major) now?"
        }
    }
}
