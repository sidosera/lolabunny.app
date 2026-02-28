import Cocoa
import CryptoKit
import SWCompression

@MainActor
protocol UpdateService {
    func fetchLatestRelease() async -> ReleaseInfo?
}

struct DisabledUpdateService: UpdateService {
    func fetchLatestRelease() async -> ReleaseInfo? {
        nil
    }
}

final class GistUpdateService: UpdateService {
    private let gistURL: URL
    private let manifestFileName: String
    private let userAgent: String
    private let session: URLSession

    init?(
        gistID: String,
        manifestFileName: String,
        userAgent: String,
        session: URLSession = .shared
    ) {
        let trimmedGistID = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedManifest = manifestFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGistID.isEmpty, !trimmedManifest.isEmpty else {
            return nil
        }
        guard let gistURL = URL(string: "https://api.github.com/gists/\(trimmedGistID)") else {
            return nil
        }
        self.gistURL = gistURL
        self.manifestFileName = trimmedManifest
        self.userAgent = userAgent
        self.session = session
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        var gistReq = URLRequest(url: gistURL)
        gistReq.timeoutInterval = 8
        gistReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        gistReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (gistData, gistResponse) = try await session.data(for: gistReq)
            guard let gistHTTP = gistResponse as? HTTPURLResponse else {
                log("gist release check failed: missing HTTP response")
                return nil
            }
            guard gistHTTP.statusCode == 200 else {
                log("gist release check failed: status=\(gistHTTP.statusCode)")
                return nil
            }
            guard let gist = try? JSONDecoder().decode(GistPayload.self, from: gistData) else {
                log("gist release check failed: invalid gist payload")
                return nil
            }

            guard let manifestFile = gist.file(named: manifestFileName),
                let manifestURL = manifestFile.rawURL
            else {
                log("gist release check failed: manifest file missing (\(manifestFileName))")
                return nil
            }

            var manifestReq = URLRequest(url: manifestURL)
            manifestReq.timeoutInterval = 8
            manifestReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            manifestReq.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            let (manifestData, manifestResponse) = try await session.data(for: manifestReq)
            guard let manifestHTTP = manifestResponse as? HTTPURLResponse else {
                log("gist release check failed: missing manifest HTTP response")
                return nil
            }
            guard manifestHTTP.statusCode == 200 else {
                log("gist release check failed: manifest status=\(manifestHTTP.statusCode)")
                return nil
            }
            guard
                let manifest = try? JSONDecoder().decode(
                    GistManifestPayload.self, from: manifestData)
            else {
                log("gist release check failed: invalid manifest payload")
                return nil
            }
            guard let selected = manifest.selectedRelease() else {
                log("gist release check failed: no releases in manifest")
                return nil
            }

            var assets: [ReleaseAsset] = []
            for assetName in selected.assets {
                let trimmedAssetName = assetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAssetName.isEmpty else {
                    continue
                }
                guard let file = gist.file(named: trimmedAssetName),
                    let rawURL = file.rawURL
                else {
                    log(
                        "gist release check failed: missing gist file for asset \(trimmedAssetName)"
                    )
                    return nil
                }
                assets.append(ReleaseAsset(name: trimmedAssetName, downloadURL: rawURL))
            }

            let version = selected.version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else {
                log("gist release check failed: selected release version is empty")
                return nil
            }
            return ReleaseInfo(version: version, assets: assets)
        } catch {
            log("gist release check failed: \(error.localizedDescription)")
            return nil
        }
    }
}

private struct GistPayload: Decodable {
    let files: [String: GistFilePayload]

    func file(named targetName: String) -> GistFilePayload? {
        if let exact = files[targetName] {
            return exact
        }
        return files.values.first { $0.filename == targetName }
    }
}

private struct GistFilePayload: Decodable {
    let filename: String
    let rawURL: URL?

    private enum CodingKeys: String, CodingKey {
        case filename
        case rawURL = "raw_url"
    }
}

private struct GistManifestPayload: Decodable {
    let latest: String?
    let releases: [GistManifestReleasePayload]

    private enum CodingKeys: String, CodingKey {
        case latest
        case releases
        case version
        case assets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try container.decodeIfPresent(String.self, forKey: .latest)

        if let list = try container.decodeIfPresent(
            [GistManifestReleasePayload].self, forKey: .releases),
            !list.isEmpty
        {
            releases = list
            return
        }

        if let version = try container.decodeIfPresent(String.self, forKey: .version),
            let assets = try container.decodeIfPresent([String].self, forKey: .assets)
        {
            releases = [GistManifestReleasePayload(version: version, assets: assets)]
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .releases,
            in: container,
            debugDescription: "Manifest must include 'releases' or ('version' and 'assets')."
        )
    }

    func selectedRelease() -> GistManifestReleasePayload? {
        let available = releases.filter {
            !$0.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !available.isEmpty else {
            return nil
        }

        if let latest = latest?.trimmingCharacters(in: .whitespacesAndNewlines),
            !latest.isEmpty,
            let matching = available.first(where: {
                $0.version.trimmingCharacters(in: .whitespacesAndNewlines) == latest
            })
        {
            return matching
        }
        return available.last ?? available.first
    }
}

private struct GistManifestReleasePayload: Decodable {
    let version: String
    let assets: [String]
}

extension AppDelegate {
    func isServerArchiveAsset(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains(Config.appName)
            && (n.contains("darwin") || n.contains("macos"))
            && n.hasSuffix(".tar.gz")
            && !n.hasSuffix(".tar.gz.sha256")
    }

    func matchesArch(_ assetName: String, archToken: String) -> Bool {
        let n = assetName.lowercased()
        let t = archToken.lowercased()
        return n.contains("-\(t).") || n.contains("-\(t)-") || n.hasSuffix("\(t).tar.gz")
    }

    func selectReleaseAssets(from release: ReleaseInfo) -> ReleaseAssetSelection? {
        let archives = release.assets.filter { isServerArchiveAsset($0.name) }
        guard !archives.isEmpty else {
            log("latest release \(release.version) has no macOS server archives")
            return nil
        }

        let aliases = architectureAliases()
        var selectedArchive: ReleaseAsset?
        for alias in aliases {
            if let match = archives.first(where: { matchesArch($0.name, archToken: alias) }) {
                selectedArchive = match
                break
            }
        }
        if selectedArchive == nil,
            let universal = archives.first(where: { $0.name.lowercased().contains("universal") })
        {
            selectedArchive = universal
        }
        if selectedArchive == nil, archives.count == 1 {
            selectedArchive = archives[0]
        }
        guard let archive = selectedArchive else {
            log(
                "no matching server archive for architecture \(architectureAliases()) in release \(release.version)"
            )
            return nil
        }

        let checksumName = archive.name + ".sha256"
        let checksum = release.assets.first { $0.name == checksumName }
        guard let checksum else {
            log("checksum asset missing for archive \(archive.name)")
            return nil
        }

        return ReleaseAssetSelection(
            version: release.version.trimmingCharacters(in: .whitespacesAndNewlines),
            archive: archive,
            checksum: checksum
        )
    }

    func shouldRunUpdateCheck(force: Bool, now: Date = Date()) -> Bool {
        if force {
            return true
        }
        if shouldSkipAutomaticUpdateChecks() {
            return false
        }
        guard let last = updateState.lastCheckedAt else {
            return true
        }
        return (now.timeIntervalSince1970 - last) >= Config.Server.autoCheckInterval
    }

    func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: Config.Server.schedulerTickInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runUpdateCheck(force: false, notify: false)
            }
        }
    }

    func runUpdateCheck(force: Bool, notify: Bool) {
        guard !isApplyingServerUpdate else {
            return
        }
        guard shouldRunUpdateCheck(force: force) else {
            return
        }
        guard !isCheckingUpdates else {
            return
        }
        isCheckingUpdates = true

        let previousServerNotified = updateState.lastNotifiedServerVersion

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performUpdateCheck()
            self.applyUpdateCheckOutcome(
                outcome,
                notify: notify,
                previousServerNotified: previousServerNotified
            )
        }
    }

    func performUpdateCheck() async -> UpdateCheckOutcome {
        let now = Date().timeIntervalSince1970
        let requiredMajor = requiredServerMajor()
        let serverCurrent = await probeRunningServerAsync() ?? currentCompatibleServerVersion()

        guard let latestRelease = await fetchLatestRelease() else {
            return UpdateCheckOutcome(
                checkedAt: now,
                serverLatestAvailable: nil,
                error: "failed to check latest release"
            )
        }

        let latest = latestRelease.version.trimmingCharacters(in: .whitespacesAndNewlines)

        var serverLatest: String?
        var checkError: String?
        if versionMatchesRequiredMajor(latest, requiredMajor: requiredMajor),
            compareVersions(latest, serverCurrent) == .orderedDescending
        {
            let hasRunnableLocalServer = resolveLaunchTarget() != nil
            if let selection = selectReleaseAssets(from: latestRelease) {
                let installedBinary = managedServerBinary(for: latest)
                let pendingBinary = pendingServerBinary(for: latest)
                if canLaunchServerBinary(installedBinary) || canLaunchServerBinary(pendingBinary) {
                    serverLatest = latest
                } else if !hasRunnableLocalServer {
                    log("auto-download skipped: no runnable local server, user permission required")
                } else if !allowAutomaticServerDownloads {
                    log("auto-download skipped: waiting for bootstrap permission")
                } else if await downloadAndStageServer(selection: selection) != nil {
                    serverLatest = latest
                } else {
                    checkError = "failed to download server \(latest)"
                }
            }
        }

        return UpdateCheckOutcome(
            checkedAt: now,
            serverLatestAvailable: serverLatest,
            error: checkError
        )
    }

    func applyUpdateCheckOutcome(
        _ outcome: UpdateCheckOutcome,
        notify: Bool,
        previousServerNotified: String?
    ) {
        isCheckingUpdates = false

        updateState.lastCheckedAt = outcome.checkedAt

        if outcome.error != nil {
            if notify {
                postNotification(
                    title: Config.displayName, body: Config.Notification.updatesCheckFailedMessage)
            }
            return
        }

        var serverUpdateToNotify: String?
        if let serverLatest = outcome.serverLatestAvailable {
            let shouldNotifyServer = notify || serverLatest != previousServerNotified
            if shouldNotifyServer {
                serverUpdateToNotify = serverLatest
                updateState.lastNotifiedServerVersion = serverLatest
            }
        } else {
            updateState.lastNotifiedServerVersion = nil
        }

        if let serverVersion = serverUpdateToNotify {
            postUpdateReadyNotification(serverVersion)
        } else if notify {
            postNotification(title: Config.displayName, body: Config.Notification.noUpdatesMessage)
        }
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        await updateService.fetchLatestRelease()
    }

    nonisolated func downloadFile(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: (@MainActor (Double?) -> Void)? = nil
    ) async -> Bool {
        var req = URLRequest(url: sourceURL)
        req.timeoutInterval = 120
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(Config.displayName, forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                log("download failed: missing HTTP response")
                return false
            }
            guard (200...299).contains(http.statusCode) else {
                log("download failed: status=\(http.statusCode)")
                return false
            }

            let fm = FileManager.default
            let expectedBytes =
                response.expectedContentLength > 0 ? response.expectedContentLength : -1
            let tempURL =
                destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".download-\(UUID().uuidString).tmp")
            if fm.fileExists(atPath: tempURL.path) {
                try fm.removeItem(at: tempURL)
            }
            guard fm.createFile(atPath: tempURL.path, contents: nil) else {
                log("download failed: could not create temp file \(tempURL.path)")
                return false
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            var succeeded = false
            defer {
                try? handle.close()
                if !succeeded {
                    try? fm.removeItem(at: tempURL)
                }
            }

            let chunkSize = 64 * 1024
            var buffer = Data()
            buffer.reserveCapacity(chunkSize)
            var bytesWritten: Int64 = 0

            if let progress {
                if expectedBytes > 0 {
                    await progress(0.0)
                } else {
                    await progress(nil)
                }
            }

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count < chunkSize {
                    continue
                }
                try handle.write(contentsOf: buffer)
                bytesWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if let progress {
                    if expectedBytes > 0 {
                        let fraction = max(
                            0.0, min(Double(bytesWritten) / Double(expectedBytes), 1.0))
                        await progress(fraction)
                    } else {
                        await progress(nil)
                    }
                }
                if Config.Server.downloadChunkDelayMillis > 0 {
                    try await Task.sleep(
                        nanoseconds: Config.Server.downloadChunkDelayMillis * 1_000_000)
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                bytesWritten += Int64(buffer.count)
            }
            try handle.synchronize()

            if let progress {
                if expectedBytes > 0 {
                    let fraction = max(0.0, min(Double(bytesWritten) / Double(expectedBytes), 1.0))
                    await progress(fraction)
                } else {
                    await progress(nil)
                }
            }

            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: tempURL, to: destinationURL)
            if let progress {
                await progress(1.0)
            }
            succeeded = true
            return true
        } catch {
            log("download failed: \(error.localizedDescription)")
            return false
        }
    }

    func sha256Hex(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            log("failed to read \(fileURL.path) for sha256")
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func parseExpectedSHA256(contents: String, archiveName: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else {
                continue
            }
            let hash = String(first).lowercased()
            guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                continue
            }
            if fields.count == 1 {
                return hash
            }
            let fileField = fields.dropFirst().map(String.init).joined(separator: " ")
            let normalized =
                fileField
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "*", with: "")
            if normalized.hasSuffix(archiveName) {
                return hash
            }
        }
        return nil
    }

    func verifyDownloadedArchive(archiveURL: URL, checksumURL: URL, archiveName: String) -> Bool {
        guard let checksumContents = try? String(contentsOf: checksumURL, encoding: .utf8) else {
            log("failed reading checksum file \(checksumURL.path)")
            return false
        }
        guard
            let expected = parseExpectedSHA256(contents: checksumContents, archiveName: archiveName)
        else {
            log("checksum file did not include a valid hash for \(archiveName)")
            return false
        }
        guard let actual = sha256Hex(for: archiveURL) else {
            return false
        }
        guard expected == actual else {
            log("checksum mismatch for \(archiveName): expected \(expected), got \(actual)")
            return false
        }
        return true
    }

    func archiveEntryOutputURL(baseDir: URL, entryName: String) -> URL? {
        var relativePath = entryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if relativePath.isEmpty {
            return nil
        }
        while relativePath.hasPrefix("./") {
            relativePath.removeFirst(2)
        }
        while relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        if relativePath.isEmpty {
            return nil
        }

        var outputURL = baseDir
        for component in relativePath.split(separator: "/") {
            let part = String(component)
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." {
                return nil
            }
            outputURL.appendPathComponent(part, isDirectory: false)
        }

        let basePath = baseDir.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        if outputPath == basePath || outputPath.hasPrefix(basePath + "/") {
            return outputURL
        }
        return nil
    }

    func extractArchive(_ archiveURL: URL, to destinationDir: URL) -> Bool {
        let fm = FileManager.default
        do {
            let compressedData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
            let tarData = try GzipArchive.unarchive(archive: compressedData)
            let entries = try TarContainer.open(container: tarData)

            for entry in entries {
                guard
                    let outputURL = archiveEntryOutputURL(
                        baseDir: destinationDir, entryName: entry.info.name)
                else {
                    log("failed to extract archive: unsafe entry path \(entry.info.name)")
                    return false
                }

                switch entry.info.type {
                case .directory:
                    try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
                case .regular, .contiguous:
                    guard let data = entry.data else {
                        log("failed to extract archive: missing file data for \(entry.info.name)")
                        return false
                    }
                    try fm.createDirectory(
                        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try data.write(to: outputURL, options: .atomic)
                    if let permissions = entry.info.permissions {
                        try fm.setAttributes(
                            [.posixPermissions: Int(permissions.rawValue)],
                            ofItemAtPath: outputURL.path)
                    }
                default:
                    log(
                        "failed to extract archive: unsupported entry type \(entry.info.type) for \(entry.info.name)"
                    )
                    return false
                }
            }
            return true
        } catch {
            log("failed to extract archive: \(error.localizedDescription)")
            return false
        }
    }

    func downloadAndStageServer(selection: ReleaseAssetSelection) async -> URL? {
        let fm = FileManager.default
        let version = selection.version
        let targetBinary = pendingServerBinary(for: version)
        if fm.isExecutableFile(atPath: targetBinary.path), canLaunchServerBinary(targetBinary) {
            return targetBinary
        }
        let archiveRemoteURL = selection.archive.downloadURL
        let checksumAsset = selection.checksum
        let checksumRemoteURL = checksumAsset.downloadURL

        guard ensureDirectory(pendingServerRoot) else {
            return nil
        }

        let stagingRoot =
            pendingServerRoot
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            log("failed to create staging directory: \(error.localizedDescription)")
            return nil
        }
        defer { try? fm.removeItem(at: stagingRoot) }

        let archiveURL = stagingRoot.appendingPathComponent(selection.archive.name)
        let checksumURL = stagingRoot.appendingPathComponent(checksumAsset.name)

        log("downloading server \(version) asset \(selection.archive.name)")
        guard
            await downloadFile(
                from: archiveRemoteURL,
                to: archiveURL,
                progress: { [weak self] fraction in
                    guard let self, self.isBootstrappingServer else {
                        return
                    }
                    let normalized = max(0.0, min(fraction ?? 0.0, 1.0))
                    let mapped = 0.30 + (normalized * 0.35)
                    self.setServerSetupState(
                        .downloading(phase: "Downloading archive", progress: mapped))
                }
            )
        else {
            return nil
        }
        guard
            await downloadFile(
                from: checksumRemoteURL,
                to: checksumURL,
                progress: { [weak self] fraction in
                    guard let self, self.isBootstrappingServer else {
                        return
                    }
                    let normalized = max(0.0, min(fraction ?? 0.0, 1.0))
                    let mapped = 0.65 + (normalized * 0.07)
                    self.setServerSetupState(
                        .downloading(phase: "Downloading checksum", progress: mapped))
                }
            )
        else {
            return nil
        }
        if isBootstrappingServer {
            setServerSetupState(.downloading(phase: "Verifying archive", progress: 0.74))
        }
        guard
            verifyDownloadedArchive(
                archiveURL: archiveURL,
                checksumURL: checksumURL,
                archiveName: selection.archive.name
            )
        else {
            return nil
        }

        let extractedDir = stagingRoot.appendingPathComponent("extract", isDirectory: true)
        do {
            try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        } catch {
            log("failed to create extraction directory: \(error.localizedDescription)")
            return nil
        }
        if isBootstrappingServer {
            setServerSetupState(.downloading(phase: "Extracting archive", progress: 0.80))
        }
        guard extractArchive(archiveURL, to: extractedDir) else {
            return nil
        }

        let extractedBinary = extractedDir.appendingPathComponent(Config.appName)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)
        } catch {
            log("failed to set executable permissions: \(error.localizedDescription)")
        }
        guard canLaunchServerBinary(extractedBinary) else {
            log("downloaded server binary is not runnable for current architecture")
            return nil
        }

        let finalArchDir = targetBinary.deletingLastPathComponent()
        let finalVersionDir = finalArchDir.deletingLastPathComponent()
        guard ensureDirectory(finalVersionDir) else {
            return nil
        }
        if fm.fileExists(atPath: finalArchDir.path) {
            try? fm.removeItem(at: finalArchDir)
        }
        do {
            if isBootstrappingServer {
                setServerSetupState(.downloading(phase: "Installing server", progress: 0.90))
            }
            try fm.moveItem(at: extractedDir, to: finalArchDir)
        } catch {
            log("failed to stage server \(version): \(error.localizedDescription)")
            return nil
        }

        let finalBinary = finalArchDir.appendingPathComponent(Config.appName)
        guard canLaunchServerBinary(finalBinary) else {
            try? fm.removeItem(at: finalArchDir)
            log("staged server \(version) failed post-install validation")
            return nil
        }
        log("staged server \(version) at \(finalBinary.path)")
        return finalBinary
    }

    func promotePendingServer(version: String) -> Bool {
        let fm = FileManager.default
        let activeArchDir = managedServerBinary(for: version).deletingLastPathComponent()
        let activeBinary = activeArchDir.appendingPathComponent(Config.appName)
        if fm.isExecutableFile(atPath: activeBinary.path), canLaunchServerBinary(activeBinary) {
            return true
        }

        let pendingArchDir = pendingServerBinary(for: version).deletingLastPathComponent()
        guard fm.fileExists(atPath: pendingArchDir.path) else {
            log("no staged server update found for \(version)")
            return false
        }

        let activeVersionDir = activeArchDir.deletingLastPathComponent()
        guard ensureDirectory(activeVersionDir) else {
            return false
        }
        if fm.fileExists(atPath: activeArchDir.path) {
            try? fm.removeItem(at: activeArchDir)
        }
        do {
            try fm.moveItem(at: pendingArchDir, to: activeArchDir)
        } catch {
            log("failed to activate staged server \(version): \(error.localizedDescription)")
            return false
        }

        guard canLaunchServerBinary(activeBinary) else {
            try? fm.removeItem(at: activeArchDir)
            log("activated server \(version) failed validation")
            return false
        }
        return true
    }

    func removeInstalledServer(version: String) {
        let fm = FileManager.default
        let archDir = managedServerBinary(for: version).deletingLastPathComponent()
        if fm.fileExists(atPath: archDir.path) {
            try? fm.removeItem(at: archDir)
        }
        let versionDir = archDir.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(atPath: versionDir.path), entries.isEmpty {
            try? fm.removeItem(at: versionDir)
        }
    }

    func removePendingServer(version: String) {
        let fm = FileManager.default
        let archDir = pendingServerBinary(for: version).deletingLastPathComponent()
        if fm.fileExists(atPath: archDir.path) {
            try? fm.removeItem(at: archDir)
        }
        let versionDir = archDir.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(atPath: versionDir.path), entries.isEmpty {
            try? fm.removeItem(at: versionDir)
        }
    }

    func waitForServerVersion(_ version: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeRunningServerAsync() == version {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func applyDownloadedServerUpdate(version: String) {
        guard !isApplyingServerUpdate else {
            log("server apply already in progress")
            return
        }
        isApplyingServerUpdate = true
        log("applying staged server update \(version)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            let previous =
                await self.probeRunningServerAsync() ?? self.currentCompatibleServerVersion()

            guard self.promotePendingServer(version: version) else {
                self.isApplyingServerUpdate = false
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.serverUpdateApplyFailedMessage)
                return
            }

            self.stopRunningServer()
            await self.startServer()
            let applied = await self.waitForServerVersion(version, timeout: 8)

            if !applied {
                self.removeInstalledServer(version: version)
                self.stopRunningServer()
                await self.startServer()
                _ = await self.waitForServerVersion(previous, timeout: 8)
            } else {
                self.removePendingServer(version: version)
            }

            self.isApplyingServerUpdate = false
            if applied {
                self.updateState.lastNotifiedServerVersion = nil
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.serverUpdatedMessage(version))
            } else {
                self.postNotification(
                    title: Config.displayName,
                    body: Config.Notification.serverUpdateApplyFailedMessage)
            }
            self.runUpdateCheck(force: true, notify: false)
        }
    }
}
