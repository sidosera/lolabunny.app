import Foundation

public enum Paths {
    static let appDirectoryName = ".lolabunny"
    static let legacyAppDirectoryName = "bunnylol"
    static let homebrewShareDirectoryNames = ["lolabunny", legacyAppDirectoryName]

    public static var runtimeDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".lolabunny", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var pidFile: URL {
        runtimeDirectory.appendingPathComponent("pid")
    }

    public static var dataHome: URL {
        if let raw = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }

        return homeDirectory
            .appendingPathComponent(".local/share", isDirectory: true)
    }

    public static var appDataHome: URL {
        dataHome.appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    public static var legacyAppDataHome: URL {
        dataHome.appendingPathComponent(legacyAppDirectoryName, isDirectory: true)
    }

    public static var historyFile: URL {
        appDataHome.appendingPathComponent("history")
    }

    public static var defaultVolumeDirectory: URL {
        let root = appDataHome
        let volume = root.appendingPathComponent("volume", isDirectory: true)
        let legacyRoot = legacyAppDataHome
        let legacyVault = legacyRoot.appendingPathComponent("vault", isDirectory: true)
        if FileManager.default.fileExists(atPath: volume.path)
            || !FileManager.default.fileExists(atPath: legacyVault.path) {
            return volume
        }
        return legacyVault
    }

    public static var executableDirectory: URL? {
        guard let executable = Bundle.main.executableURL else {
            return nil
        }
        return executable.deletingLastPathComponent()
    }

    public static func versionString() -> String {
        for candidate in versionFileCandidates() {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }
            let version = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty {
                return version
            }
        }
        return "dev"
    }

    public static func pluginDirectories() -> [URL] {
        var candidates: [URL] = []

        if let executableDirectory {
            candidates.append(
                executableDirectory
                    .appendingPathComponent("lola-core", isDirectory: true)
                    .appendingPathComponent("commands", isDirectory: true)
            )
        }

        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        candidates.append(
            currentDirectory
                .appendingPathComponent("lola-core", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
        )
        candidates.append(
            currentDirectory
                .appendingPathComponent("..", isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("lola-core", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
        )

        let homeAppDirectory = homeDirectory.appendingPathComponent(appDirectoryName, isDirectory: true)
        candidates.append(homeAppDirectory)
        candidates.append(homeAppDirectory.appendingPathComponent("commands", isDirectory: true))
        candidates.append(appDataHome.appendingPathComponent("commands", isDirectory: true))
        candidates.append(legacyAppDataHome.appendingPathComponent("commands", isDirectory: true))

        for prefix in ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"] {
            let root = URL(fileURLWithPath: prefix, isDirectory: true)
            let brew = root.appendingPathComponent("bin/brew")
            if FileManager.default.isExecutableFile(atPath: brew.path) {
                for directoryName in homebrewShareDirectoryNames {
                    candidates.append(
                        root.appendingPathComponent("share", isDirectory: true)
                            .appendingPathComponent(directoryName, isDirectory: true)
                            .appendingPathComponent("commands", isDirectory: true)
                    )
                }
            }
        }

        var seen = Set<String>()
        return candidates.flatMap { commandDirectoryCandidates(from: $0) }.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  isDirectory(at: url) else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private static func commandDirectoryCandidates(from url: URL) -> [URL] {
        guard isDirectory(at: url) else {
            return [url]
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let childDirectories = children.filter { isDirectory(at: $0) }

        return [url] + childDirectories.map { $0.resolvingSymlinksInPath() }
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static var homeDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["HOME"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func versionFileCandidates() -> [URL] {
        var candidates: [URL] = []
        if let executableDirectory {
            candidates.append(executableDirectory.appendingPathComponent(".version"))
        }

        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        candidates.append(currentDirectory.appendingPathComponent(".version"))
        candidates.append(
            currentDirectory
                .appendingPathComponent("..", isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent(".version")
        )
        return candidates
    }
}
