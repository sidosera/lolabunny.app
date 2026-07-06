import Foundation

enum Paths {
    static let appPrefix = "bunnylol"

    static var runtimeDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".lolabunny", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var pidFile: URL {
        runtimeDirectory.appendingPathComponent("pid")
    }

    static var dataHome: URL {
        if let raw = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
    }

    static var appDataHome: URL {
        dataHome.appendingPathComponent(appPrefix, isDirectory: true)
    }

    static var historyFile: URL {
        appDataHome.appendingPathComponent("history")
    }

    static var defaultVolumeDirectory: URL {
        let root = appDataHome
        let volume = root.appendingPathComponent("volume", isDirectory: true)
        let legacyVault = root.appendingPathComponent("vault", isDirectory: true)
        if FileManager.default.fileExists(atPath: volume.path)
            || !FileManager.default.fileExists(atPath: legacyVault.path) {
            return volume
        }
        return legacyVault
    }

    static var executableDirectory: URL? {
        guard let executable = Bundle.main.executableURL else {
            return nil
        }
        return executable.deletingLastPathComponent()
    }

    static func versionString() -> String {
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

    static func pluginDirectories() -> [URL] {
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

        candidates.append(appDataHome.appendingPathComponent("commands", isDirectory: true))

        for prefix in ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"] {
            let root = URL(fileURLWithPath: prefix, isDirectory: true)
            let brew = root.appendingPathComponent("bin/brew")
            if FileManager.default.isExecutableFile(atPath: brew.path) {
                candidates.append(
                    root.appendingPathComponent("share", isDirectory: true)
                        .appendingPathComponent(appPrefix, isDirectory: true)
                        .appendingPathComponent("commands", isDirectory: true)
                )
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
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
