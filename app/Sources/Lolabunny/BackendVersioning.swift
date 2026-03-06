import Foundation

extension AppDelegate {
    func backendVersionDirectory(for version: String, locked: Bool = false) -> URL {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = locked ? "\(normalized).locked" : normalized
        return managedBackendRoot
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    func backendBinary(for version: String) -> URL {
        backendVersionDirectory(for: version)
            .appendingPathComponent(Config.appName)
    }

    func lockedBackendBinary(for version: String) -> URL {
        backendVersionDirectory(for: version, locked: true)
            .appendingPathComponent(Config.appName)
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

    var backendConfigURL: URL {
        URL(fileURLWithPath: Config.Backend.configFile, isDirectory: false)
    }

    func configuredBackendVersion() -> String? {
        guard let contents = try? String(contentsOf: backendConfigURL, encoding: .utf8) else {
            return nil
        }
        let pattern = #"^\s*backend_version\s*=\s*"([^"]+)"\s*$"#
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

    func setConfiguredBackendVersion(_ version: String) {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let configURL = backendConfigURL
        guard ensureDirectory(configURL.deletingLastPathComponent()) else {
            return
        }
        let contents = "backend_version = \"\(normalized)\"\n"
        do {
            try contents.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            log("failed to write backend config: \(error.localizedDescription)")
        }
    }

    func canLaunchBackendBinary(_ binary: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return false
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            log("binary not launchable (\(binary.path)): \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            log("binary version probe failed (\(binary.path)), exit=\(proc.terminationStatus)")
            return false
        }
        return true
    }

    func installedBackendVersions() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: managedBackendRoot.path) else {
            return []
        }
        return entries.filter { version in
            if version.hasPrefix(".") || version.hasSuffix(".locked") {
                return false
            }
            return fm.isExecutableFile(atPath: backendBinary(for: version).path)
        }
    }

    func downloadedLockedBackendVersions() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: managedBackendRoot.path) else {
            return []
        }
        var versions: [String] = []
        for entry in entries {
            guard let version = unlockedVersionName(fromLockedEntry: entry) else {
                continue
            }
            if fm.isExecutableFile(atPath: lockedBackendBinary(for: version).path) {
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

    func requiredBackendMajor() -> String {
        majorVersion(bundledVersion())
    }

    func versionMatchesRequiredMajor(_ version: String, requiredMajor: String) -> Bool {
        let expectedMajor = requiredMajor.trimmingCharacters(in: .whitespacesAndNewlines)
        if expectedMajor.isEmpty {
            // Dev or non-semver app versions may not define a strict backend major.
            return true
        }
        if expectedMajor.range(of: #"^\d+$"#, options: .regularExpression) == nil {
            // Non-numeric app majors (for example "alpha") are treated as unconstrained.
            return true
        }
        return majorVersion(version) == expectedMajor
    }

    func currentCompatibleBackendVersion() -> String {
        let requiredMajor = requiredBackendMajor()
        if let configured = configuredBackendVersion(),
            versionMatchesRequiredMajor(configured, requiredMajor: requiredMajor)
        {
            return configured
        }
        let bundled = bundledVersion()
        return installedCompatibleVersions(requiredMajor: requiredMajor).first ?? bundled
    }

    func installedCompatibleVersions(requiredMajor: String) -> [String] {
        installedBackendVersions()
            .filter { versionMatchesRequiredMajor($0, requiredMajor: requiredMajor) }
            .sorted { compareVersions($0, $1) == .orderedDescending }
    }

    func downloadedCompatibleVersions(requiredMajor: String) -> [String] {
        downloadedLockedBackendVersions()
            .filter { versionMatchesRequiredMajor($0, requiredMajor: requiredMajor) }
            .sorted { compareVersions($0, $1) == .orderedDescending }
    }

    func resolveLaunchTarget() -> (binary: URL, version: String)? {
        let requiredMajor = requiredBackendMajor()
        let configured = configuredBackendVersion()
        if let configured {
            if !versionMatchesRequiredMajor(configured, requiredMajor: requiredMajor) {
                log(
                    "configured backend \(configured) does not match required major \(requiredMajor), ignoring"
                )
            } else {
                let configuredBinary = backendBinary(for: configured)
                if canLaunchBackendBinary(configuredBinary) {
                    return (configuredBinary, configured)
                }
                log("configured backend \(configured) is not runnable, searching installed versions")
            }
        }

        for version in installedCompatibleVersions(requiredMajor: requiredMajor) {
            let candidate = backendBinary(for: version)
            if canLaunchBackendBinary(candidate) {
                if configured != version {
                    setConfiguredBackendVersion(version)
                }
                return (candidate, version)
            }
            log("cached backend \(version) is not runnable, skipping")
        }
        return nil
    }
}
