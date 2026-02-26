import Cocoa

enum Config {
    static let bundleIdentifier = "com.sidosera.lolabunny"
    static let appName = "lolabunny"
    static let displayName = "Lolabunny"
    static let serverPort: UInt16 = 8085
    static let serverBaseURL = URL(string: "http://localhost:\(serverPort)")!

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
        static let xdgPrefix = "bunnylol"
        static let githubOwner = "sidosera"
        static let githubRepo = "lolabunny.app"
        static let latestReleaseAPI = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest"
        static let autoCheckInterval: TimeInterval = 24 * 60 * 60
        static let schedulerTickInterval: TimeInterval = 60 * 60
        static let dataHome: String = {
            let env = ProcessInfo.processInfo.environment
            if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
                return xdg
            }
            return NSHomeDirectory() + "/.local/share"
        }()
        static let installRoot = dataHome + "/\(xdgPrefix)/servers"
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
        static let applyUpdateAction = "lolabunny-server-update-apply"
        static let deferUpdateAction = "lolabunny-server-update-later"
        static let serverVersionKey = "server_version"
        static let updatesCheckFailedMessage = "Update check failed."
        static let noUpdatesMessage = "No updates available."
        static let serverUpdateApplyFailedMessage = "Could not apply downloaded server update."

        static func serverUpdateReadyMessage(_ version: String) -> String {
            "Server update \(version) downloaded. Update now?"
        }

        static func serverUpdatedMessage(_ version: String) -> String {
            "Server updated to \(version)."
        }
    }
}
