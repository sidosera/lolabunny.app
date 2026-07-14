import Foundation

extension AppDelegate {
    func serverVersionDirectory(for version: String, locked: Bool = false) -> URL {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = locked ? "\(normalized).locked" : normalized
        return managedServerRoot
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    func serverBinary(for version: String) -> URL {
        serverVersionDirectory(for: version)
            .appendingPathComponent(Config.serverExecutableName)
    }

    func lockedServerBinary(for version: String) -> URL {
        serverVersionDirectory(for: version, locked: true)
            .appendingPathComponent(Config.serverExecutableName)
    }

    func unlockedVersionName(fromLockedEntry entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".locked") else {
            return nil
        }
        let version = String(trimmed.dropLast(".locked".count))
        return version.isEmpty ? nil : version
    }

    func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            log("failed to create directory \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    var serverConfigURL: URL {
        URL(fileURLWithPath: Config.Server.configFile, isDirectory: false)
    }

    func configuredServerVersion() -> String? {
        guard let contents = try? String(contentsOf: serverConfigURL, encoding: .utf8) else {
            return nil
        }
        let pattern = #"^\s*server_version\s*=\s*"([^"]+)"\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else {
            return nil
        }
        let ns = contents as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: contents, options: [], range: range),
            match.numberOfRanges > 1
        else {
            return nil
        }
        let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func setConfiguredServerVersion(_ version: String) {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let configURL = serverConfigURL
        guard ensureDirectory(configURL.deletingLastPathComponent()) else {
            return
        }
        let contents = "server_version = \"\(normalized)\"\n"
        do {
            try contents.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            log("failed to write widget-server config: \(error.localizedDescription)")
        }
    }

    func clearConfiguredServerVersion() {
        let configURL = serverConfigURL
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: configURL)
        } catch {
            log("failed to clear widget-server config: \(error.localizedDescription)")
        }
    }

    func canLaunchServerBinary(_ binary: URL) -> Bool {
        ServerArchiveUtils.canLaunchBinary(binary)
    }

    func detectedServerVersion(from binary: URL) -> String? {
        ServerArchiveUtils.detectedVersion(from: binary)
    }

    func installedServerVersions() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: managedServerRoot.path) else {
            return []
        }
        return entries.filter { version in
            if version.hasPrefix(".") || version.hasSuffix(".locked") {
                return false
            }
            return fm.isExecutableFile(atPath: serverBinary(for: version).path)
        }
    }

    func downloadedLockedServerVersions() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: managedServerRoot.path) else {
            return []
        }
        var versions: [String] = []
        for entry in entries {
            guard let version = unlockedVersionName(fromLockedEntry: entry) else {
                continue
            }
            if fm.isExecutableFile(atPath: lockedServerBinary(for: version).path) {
                versions.append(version)
            }
        }
        return versions
    }

    func parseSemVer(_ version: String) -> SemVer? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let core = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? raw
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else {
            return nil
        }
        var patch = 0
        if parts.count == 3 {
            guard let value = Int(parts[2]) else {
                return nil
            }
            patch = value
        }
        return SemVer(major: major, minor: minor, patch: patch)
    }

    func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = parseSemVer(lhs), let right = parseSemVer(rhs) {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return lhs.compare(rhs, options: .numeric)
    }

    func requiredServerMajor() -> String {
        majorVersion(bundledVersion())
    }

    func versionMatchesRequiredMajor(_ version: String, requiredMajor: String) -> Bool {
        let expectedMajor = requiredMajor.trimmingCharacters(in: .whitespacesAndNewlines)
        if expectedMajor.isEmpty {
            // Dev or non-semver widget versions may not define a strict widget-server major.
            return true
        }
        if expectedMajor.range(of: #"^\d+$"#, options: .regularExpression) == nil {
            // Non-numeric widget majors (for example "alpha") are treated as unconstrained.
            return true
        }
        return majorVersion(version) == expectedMajor
    }

    func currentCompatibleServerVersion() -> String {
        let requiredMajor = requiredServerMajor()
        if let configured = configuredServerVersion(),
            versionMatchesRequiredMajor(configured, requiredMajor: requiredMajor)
        {
            return configured
        }
        let bundled = bundledVersion()
        return installedCompatibleVersions(requiredMajor: requiredMajor).first ?? bundled
    }

    func installedCompatibleVersions(requiredMajor: String) -> [String] {
        installedServerVersions()
            .filter { versionMatchesRequiredMajor($0, requiredMajor: requiredMajor) }
            .sorted { compareVersions($0, $1) == .orderedDescending }
    }

    func downloadedCompatibleVersions(requiredMajor: String) -> [String] {
        downloadedLockedServerVersions()
            .filter { versionMatchesRequiredMajor($0, requiredMajor: requiredMajor) }
            .sorted { compareVersions($0, $1) == .orderedDescending }
    }

    func resolveLaunchTarget() -> (binary: URL, version: String)? {
        let requiredMajor = requiredServerMajor()
        let configured = configuredServerVersion()
        if let configured {
            if !versionMatchesRequiredMajor(configured, requiredMajor: requiredMajor) {
                log(
                    "configured widget-server \(configured) does not match required major \(requiredMajor), ignoring"
                )
            } else {
                let configuredBinary = serverBinary(for: configured)
                if canLaunchServerBinary(configuredBinary) {
                    return (configuredBinary, configured)
                }
                log("configured widget-server \(configured) is not runnable, searching installed versions")
            }
        }

        for version in installedCompatibleVersions(requiredMajor: requiredMajor) {
            let candidate = serverBinary(for: version)
            if canLaunchServerBinary(candidate) {
                if configured != version {
                    setConfiguredServerVersion(version)
                }
                return (candidate, version)
            }
            log("cached widget-server \(version) is not runnable, skipping")
        }
        return nil
    }
}
