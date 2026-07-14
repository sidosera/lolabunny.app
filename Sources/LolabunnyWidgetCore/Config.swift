import AppKit
import Darwin
import XDG

enum Config {
    static var bundleIdentifier: String { Config.plistString(
        keys: ["LolabunnyBundleIdentifier", "CFBundleIdentifier"]
    ) ?? ProcessInfo.processInfo.processName }
    static let serverExecutableName = "widget-server"
    static let displayName = "Lolabunny"
    static var serverPort: UInt16 {
        #if DEBUG
        if let raw = environmentString(for: "LolabunnyServerPort"), let port = UInt16(raw) {
            return port
        }
        return Development.serverPort
        #else
        return Config.plistValue("LolabunnyServerPort") ?? 18085
        #endif
    }
    /// Same host as `serve --address` (see `LolabunnyServerAddress`). Avoid `localhost` so health checks do not hit IPv6 while the widget-server listens on IPv4.
    static var serverAddress: String { Config.plistString("LolabunnyServerAddress") ?? "127.0.0.1" }
    static var serverBaseURL: URL { URL(string: "http://\(serverAddress):\(serverPort)")! }

    static func plistString(_ key: String) -> String? {
        plistString(keys: [key])
    }

    static func plistString(keys: [String]) -> String? {
        for key in keys {
            if let value = environmentString(for: key) {
                return value
            }
            if let raw = Bundle.main.object(forInfoDictionaryKey: key),
                let value = normalizePlistStringValue(raw)
            {
                return value
            }
            if let value = developmentInfoDictionary[key] {
                return value
            }
        }
        return nil
    }

    private static func environmentString(for key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let aliases: [String] = [
            key,
            environmentAliases[key] ?? ""
        ].filter { !$0.isEmpty }

        for alias in aliases {
            if let raw = environment[alias],
               let value = normalizePlistStringValue(raw) {
                return value
            }
        }
        return nil
    }

    private static let environmentAliases: [String: String] = [
        "LolabunnyServerAddress": "LOLABUNNY_SERVER_ADDRESS",
        "LolabunnyServerLaunchHealthTimeoutSeconds": "LOLABUNNY_SERVER_LAUNCH_HEALTH_TIMEOUT_SECONDS",
        "LolabunnyServerLogLevel": "LOLABUNNY_SERVER_LOG_LEVEL",
        "LolabunnyServerPort": "LOLABUNNY_SERVER_PORT",
        "LolabunnyServerRuntimeDir": "LOLABUNNY_SERVER_RUNTIME_DIR",
        "LolabunnyServerVersion": "LOLABUNNY_SERVER_VERSION",
        "LolabunnyServerWatchdogIntervalSeconds": "LOLABUNNY_SERVER_WATCHDOG_INTERVAL_SECONDS",
        "LolabunnyServerExternallyManaged": "LOLABUNNY_SERVER_EXTERNALLY_MANAGED",
        "LolabunnyDataRoot": "LOLABUNNY_DATA_ROOT",
        "LolabunnyDefaultSearch": "LOLABUNNY_DEFAULT_SEARCH",
        "LolabunnyHistoryEnabled": "LOLABUNNY_HISTORY_ENABLED",
        "LolabunnyHistoryMaxEntries": "LOLABUNNY_HISTORY_MAX_ENTRIES",
        "LolabunnyUpdateArchiveBaseURL": "LOLABUNNY_UPDATE_ARCHIVE_BASE_URL",
        "LolabunnyUpdateArchiveVersion": "LOLABUNNY_UPDATE_ARCHIVE_VERSION",
        "LolabunnyUpdateLocalStreamDelayMs": "LOLABUNNY_UPDATE_LOCAL_STREAM_DELAY_MS",
        "LolabunnyUpdateReleaseTag": "LOLABUNNY_UPDATE_RELEASE_TAG",
        "LolabunnyUpdateReleasesURL": "LOLABUNNY_UPDATE_RELEASES_URL",
        "LolabunnyVolumePath": "LOLABUNNY_VOLUME_PATH",
    ]

    private static func normalizePlistStringValue(_ raw: Any) -> String? {
        if let string = raw as? String {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let number = raw as? NSNumber {
            let value = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static let developmentInfoDictionary: [String: String] = {
        for path in developmentInfoPlistCandidatePaths() {
            if let raw = NSDictionary(contentsOfFile: path) as? [String: Any] {
                var parsed: [String: String] = [:]
                for (key, value) in raw {
                    if let normalized = normalizePlistStringValue(value) {
                        parsed[key] = normalized
                    }
                }
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }
        return [:]
    }()

    private static func developmentInfoPlistCandidatePaths() -> [String] {
        var candidates: [String] = []
        let sourceURL = URL(fileURLWithPath: #filePath)
        let appDir = sourceURL
            .deletingLastPathComponent()   // Lolabunny
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // widget
        candidates.append(appDir.appendingPathComponent("Info.plist").path)

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Info.plist").path)
        candidates.append(cwd.appendingPathComponent("Bundle/Info.plist").path)

        var deduped: [String] = []
        var seen = Set<String>()
        for path in candidates {
            if seen.insert(path).inserted {
                deduped.append(path)
            }
        }
        return deduped
    }

    static func plistValue<T: LosslessStringConvertible>(_ key: String) -> T? {
        guard let raw = plistString(key) else {
            return nil
        }
        return T(raw)
    }

    static func plistBool(_ key: String) -> Bool? {
        guard let raw = plistString(key)?.lowercased() else {
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

    enum Icon {
        static let size = NSSize(width: 18, height: 18)
        static let variants = ["bunny", "bunny@2x"]
        static let fileType = "png"
    }

    enum Log {
        static let path = NSHomeDirectory() + "/Library/Logs/\(Config.displayName).log"
    }

    enum Server {
        static var runtimeDir: String {
            #if DEBUG
            if environmentString(for: "LolabunnyServerRuntimeDir") == nil {
                return Config.Development.runtimeDir.path
            }
            #endif
            return Config.plistString("LolabunnyServerRuntimeDir") ?? (NSTemporaryDirectory() + ".lolabunny")
        }
        static var pidFile: String { runtimeDir + "/pid" }
        static var launchArgsSignatureFile: String { runtimeDir + "/widget-server-args.sig" }
        static var address: String { Config.serverAddress }
        static var logLevel: String { Config.plistString("LolabunnyServerLogLevel") ?? "normal" }
        static var defaultSearch: String { Config.plistString("LolabunnyDefaultSearch") ?? "google" }
        static var historyEnabled: Bool { Config.plistBool("LolabunnyHistoryEnabled") ?? true }
        static var historyMaxEntries: Int { Config.plistValue("LolabunnyHistoryMaxEntries") ?? 1000 }
        static var updateReleasesURL: URL? {
            #if DEBUG
            if environmentString(for: "LolabunnyUpdateReleasesURL") == nil,
               environmentString(for: "LolabunnyUpdateArchiveBaseURL") == nil {
                return Config.Development.updateReleasesURL
            }
            #endif
            guard let raw = Config.plistString(
                keys: ["LolabunnyUpdateReleasesURL", "LolabunnyUpdateArchiveBaseURL"]
            ) else {
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }

            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                    .standardizedFileURL
            }

            guard
                let url = URL(string: trimmed),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https" || scheme == "file"
            else {
                return nil
            }
            return url.isFileURL ? url.standardizedFileURL : url
        }
        static var updateReleaseTag: String? { Config.plistString(
            keys: ["LolabunnyUpdateReleaseTag", "LolabunnyUpdateArchiveVersion"]
        ) }
        static var updateLocalStreamDelayMillis: UInt64 {
            Config.plistValue("LolabunnyUpdateLocalStreamDelayMs") ?? 0
        }
        static var volumePath: String? {
            #if DEBUG
            if environmentString(for: "LolabunnyVolumePath") == nil {
                return Config.Development.volumeDir.path
            }
            #endif
            return Config.plistString("LolabunnyVolumePath")
        }
        static let autoCheckInterval: TimeInterval = 24 * 60 * 60
        static let schedulerTickInterval: TimeInterval = 60 * 60
        static var watchdogIntervalSeconds: TimeInterval {
            Config.plistValue("LolabunnyServerWatchdogIntervalSeconds") ?? 20
        }
        static var launchHealthTimeoutSeconds: TimeInterval {
            Config.plistValue("LolabunnyServerLaunchHealthTimeoutSeconds") ?? 10
        }
        static var externallyManaged: Bool {
            Config.plistBool("LolabunnyServerExternallyManaged") ?? false
        }
        static var processEnvironmentOverrides: [String: String] {
            #if DEBUG
            [
                "TMPDIR": Config.Development.tmpDir.path + "/",
                "XDG_DATA_HOME": Config.Development.dataDir.path,
            ]
            #else
            [:]
            #endif
        }
        static var dataRoot: String {
            #if DEBUG
            if environmentString(for: "LolabunnyDataRoot") == nil {
                return Config.Development.dataDir.path
            }
            #endif
            if let configured = Config.plistString("LolabunnyDataRoot") {
                return (configured as NSString).expandingTildeInPath
            }
            if let dirs = try? BaseDirectories(prefixAll: ".lolabunny") {
                return dirs.dataHomePrefixed.string
            }
            return NSHomeDirectory() + "/.local/share/.lolabunny"
        }
        static var configFile: String { dataRoot + "/config.toml" }
        static var installRoot: String { dataRoot + "/servers" }
        static var version: String {
            if let configured = Config.plistString("LolabunnyServerVersion") {
                return configured
            }
            guard let path = Bundle.main.path(forResource: ".version", ofType: nil),
                  let contents = try? String(contentsOfFile: path, encoding: .utf8)
            else {
                return "unknown"
            }
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    #if DEBUG
    enum Development {
        static let updateReleasesURL = URL(string: "http://127.0.0.1:18086/releases")!
        static let sessionRoot: URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("lolabunny-local-\(UUID().uuidString)", isDirectory: true)
        }()
        static let tmpDir = sessionRoot.appendingPathComponent("tmp", isDirectory: true)
        static let runtimeDir = tmpDir.appendingPathComponent(".lolabunny", isDirectory: true)
        static let dataDir = sessionRoot.appendingPathComponent("data", isDirectory: true)
        static let volumeDir = sessionRoot.appendingPathComponent("volume", isDirectory: true)
        static let serverPort: UInt16 = availablePort() ?? 18085

        private static func availablePort() -> UInt16? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                return nil
            }
            defer { close(fd) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                return nil
            }

            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    getsockname(fd, socketAddress, &length)
                }
            }
            guard nameResult == 0 else {
                return nil
            }
            return UInt16(bigEndian: bound.sin_port)
        }
    }
    #endif

    enum Menu {
        static let openSearch = "Search"
        static let openBindings = "Open Bindings"
        static let launchAtLogin = "Launch at Login"
        static let quit = "Quit"
    }

    enum CommandPalette {
        static let hotKeyLabel = "⌘P"
        static let placeholder = "Search"
    }

    enum Notification {
        static let identifier = "lolabunny-notification"
        static let updatePromptCategory = "lolabunny-widget-server-update-prompt"
        static let bootstrapPromptCategory = "lolabunny-widget-server-bootstrap-prompt"
        static let applyUpdateAction = "lolabunny-widget-server-update-apply"
        static let deferUpdateAction = "lolabunny-widget-server-update-later"
        static let bootstrapDownloadAction = "lolabunny-widget-server-bootstrap-download"
        static let bootstrapLaterAction = "lolabunny-widget-server-bootstrap-later"
        static let serverVersionKey = "server_version"
        static let serverRequiredMajorKey = "server_required_major"
        static let updatesCheckFailedMessage = "Update check failed."
        static let noUpdatesMessage = "No updates available."
        static let serverUpdateApplyFailedMessage = "Could not apply downloaded widget-server update."
        static let serverBootstrapFailedMessage = "Could not download a compatible widget-server."

        static func serverUpdateReadyMessage(_ version: String) -> String {
            "Server update \(version) downloaded. Update now?"
        }

        static func serverUpdatedMessage(_ version: String) -> String {
            "Server updated to \(version)."
        }

        static func serverBootstrapPermissionMessage(requiredMajor: String) -> String {
            let major = requiredMajor.trimmingCharacters(in: .whitespacesAndNewlines)
            if major.isEmpty {
                return "Download compatible widget-server now?"
            }
            return "Download compatible widget-server major \(major) now?"
        }
    }
}
