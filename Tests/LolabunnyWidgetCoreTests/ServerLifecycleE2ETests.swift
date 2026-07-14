import Darwin
import Foundation
import LolabunnyDistributionSupport
import XCTest
@testable import LolabunnyWidgetCore

@MainActor
final class ServerLifecycleE2ETests: XCTestCase {
    func testServerHandlesHealthAndRedirects() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            let version = try sandbox.serverVersion(binary)
            let process = try sandbox.launchServer(binary)
            defer { sandbox.terminate(process) }

            try await sandbox.waitForHealth(version)

            let redirect = try await sandbox.redirectLocation(for: "lower MiXeD Value")
            XCTAssertTrue(redirect == "data:text/plain;charset=utf-8,mixed%20value")
        }
    }

    func testBootstrapInstallsServerFromMockRelease() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            try sandbox.publishRelease(version: "v1.0.0", binary: binary)

            let widget = AppDelegate()
            let installed = await widget.bootstrapServerFromDistribution(
                requiredMajor: "1",
                downloader: sandbox.downloader
            )

            XCTAssertTrue(installed?.version == "v1.0.0")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: "v1.0.0").path))
            XCTAssertTrue(widget.configuredServerVersion() == "v1.0.0")
        }
    }

    func testStagedUpdateActivatesCompatibleRelease() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            let widget = AppDelegate()

            try sandbox.publishRelease(version: "v1.0.0", binary: binary)
            let installed = await widget.bootstrapServerFromDistribution(
                requiredMajor: "1",
                downloader: sandbox.downloader
            )
            XCTAssertTrue(installed?.version == "v1.0.0")

            try sandbox.publishRelease(version: "v1.1.0", binary: binary)
            let maybeRelease = await widget.fetchLatestRelease()
            let release = try XCTUnwrap(maybeRelease)
            let staged = await widget.downloadAndStageServer(
                version: "v1.1.0",
                archiveURL: release.archiveURL,
                downloader: sandbox.downloader
            )

            XCTAssertTrue(staged?.version == "v1.1.0")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.lockedBinary(version: "v1.1.0").path))
            XCTAssertTrue(widget.activateDownloadedServer(version: "v1.1.0"))
            XCTAssertTrue(widget.configuredServerVersion() == "v1.1.0")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: "v1.1.0").path))
        }
    }

    func testCorruptReleaseDoesNotInstall() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            try sandbox.publishRelease(version: "v1.2.0", binary: binary, corruptChecksum: true)

            let widget = AppDelegate()
            let installed = await widget.bootstrapServerFromDistribution(
                requiredMajor: "1",
                downloader: sandbox.downloader
            )

            XCTAssertTrue(installed == nil)
            XCTAssertTrue(widget.configuredServerVersion() == nil)
            XCTAssertTrue(!FileManager.default.fileExists(atPath: sandbox.activeBinary(version: "v1.2.0").path))
        }
    }

    func testStartupDownloadsFromConfiguredLocalReleaseServerAndRunsServer() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            _ = try await sandbox.launchLocalReleaseServer(version: "v1.0.0", binary: binary)

            let widget = AppDelegate()
            await widget.startServer()

            guard case .WaitForDownloadPermission(let requiredMajor) = widget.serverSetupState else {
                XCTFail("Expected startup to request widget-server download, got \(widget.serverSetupState)")
                return
            }
            XCTAssertTrue(requiredMajor == "1")

            await widget.beginBootstrapServerDownload(requiredMajor: requiredMajor)
            defer { widget.stopRunningServer() }

            guard case .Ready(let version) = widget.serverSetupState else {
                XCTFail("Expected downloaded widget-server to become ready, got \(widget.serverSetupState)")
                return
            }

            XCTAssertTrue(version == "v1.0.0")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: "v1.0.0").path))

            let redirect = try await sandbox.redirectLocation(for: "lower MiXeD Value")
            XCTAssertTrue(redirect == "data:text/plain;charset=utf-8,mixed%20value")
        }
    }

    func testUserBootstrapInstallsServerAndReturnsHealthStatus() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            let version = "v1.4.0"
            _ = try await sandbox.launchLocalReleaseServer(version: version, binary: binary)

            let widget = AppDelegate()
            await widget.startServer()

            guard case .WaitForDownloadPermission(let requiredMajor) = widget.serverSetupState else {
                XCTFail("Expected widget to wait for user download permission, got \(widget.serverSetupState)")
                return
            }

            await widget.beginBootstrapServerDownload(requiredMajor: requiredMajor)
            defer { widget.stopRunningServer() }

            guard case .Ready(let readyVersion) = widget.serverSetupState else {
                XCTFail("Expected widget to install and launch widget-server, got \(widget.serverSetupState)")
                return
            }

            XCTAssertTrue(readyVersion == version)
            XCTAssertTrue(widget.configuredServerVersion() == version)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: version).path))

            let status = try await sandbox.serverHealthStatus()
            XCTAssertTrue(status.code == 200)
            XCTAssertTrue(status.body == version)
        }
    }

    func testLocalReleaseServerAcceptsUploadedBinaryAndAppDiscoversIt() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildServerBinary()
            let localReleaseServer = try await sandbox.launchLocalReleaseServer()

            try await sandbox.uploadRelease(version: "v1.3.0", binary: binary)
            XCTAssertTrue(!localReleaseServer.releasesURL.isEmpty)

            let widget = AppDelegate()
            let maybeRelease = await widget.fetchLatestRelease()
            let release = try XCTUnwrap(maybeRelease)
            XCTAssertTrue(release.version == "v1.3.0")
            XCTAssertTrue(release.archiveURL.absoluteString.contains("/releases/download/v1.3.0/"))

            let installed = await widget.bootstrapServerFromDistribution(requiredMajor: "1")
            XCTAssertTrue(installed?.version == "v1.3.0")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: "v1.3.0").path))
        }
    }
}

@MainActor
private func withE2ESandbox(
    _ body: (E2ESandbox) async throws -> Void
) async throws {
    let sandbox = try E2ESandbox()
    defer { sandbox.cleanup() }
    try await body(sandbox)
}

@MainActor
private final class E2ESandbox {
    let root: URL
    let dataRoot: URL
    let runtimeDir: URL
    let releasesDir: URL
    let volumeDir: URL
    let port: UInt16
    let downloader = LocalhostServerDownloader(streamDelayMillis: 0)

    private var previousEnvironment: [String: String?] = [:]

    init() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lolabunny-e2e-\(UUID().uuidString)", isDirectory: true)
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        releasesDir = root.appendingPathComponent("releases", isDirectory: true)
        volumeDir = root.appendingPathComponent("volume", isDirectory: true)
        port = try Self.availablePort()

        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: releasesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: volumeDir, withIntermediateDirectories: true)

        setEnvironment([
            "LOLABUNNY_SERVER_ADDRESS": "127.0.0.1",
            "LOLABUNNY_SERVER_PORT": "\(port)",
            "LOLABUNNY_SERVER_RUNTIME_DIR": runtimeDir.path,
            "LOLABUNNY_SERVER_VERSION": "v1.0.0",
            "LOLABUNNY_DATA_ROOT": dataRoot.path,
            "LOLABUNNY_HISTORY_ENABLED": "false",
            "LOLABUNNY_UPDATE_LOCAL_STREAM_DELAY_MS": "0",
            "LOLABUNNY_UPDATE_RELEASE_TAG": "latest",
            "LOLABUNNY_UPDATE_RELEASES_URL": releasesDir.path,
            "LOLABUNNY_VOLUME_PATH": volumeDir.path,
        ])
    }

    func cleanup() {
        restoreEnvironment()
        try? FileManager.default.removeItem(at: root)
    }

    func buildServerBinary() throws -> URL {
        let repoRoot = try Self.repoRoot()
        let scratchPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lolabunny-e2e-swiftpm", isDirectory: true)
        let buildEnvironment = [
            "HOME": NSTemporaryDirectory(),
            "CLANG_MODULE_CACHE_PATH": URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("lolabunny-e2e-module-cache", isDirectory: true)
                .path,
        ]

        _ = try run(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swift", "build",
                "--disable-sandbox",
                "--package-path", repoRoot.path,
                "--scratch-path", scratchPath.path,
                "--configuration", "debug",
                "--product", "widget-server",
            ],
            environment: buildEnvironment,
            currentDirectory: repoRoot
        )
        let binPath = try run(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swift", "build",
                "--disable-sandbox",
                "--package-path", repoRoot.path,
                "--scratch-path", scratchPath.path,
                "--configuration", "debug",
                "--product", "widget-server",
                "--show-bin-path",
            ],
            environment: buildEnvironment,
            currentDirectory: repoRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: binPath).appendingPathComponent("widget-server")
    }

    func launchLocalReleaseServer(version: String? = nil, binary: URL? = nil) async throws -> LocalReleaseServer {
        let releasePort = try Self.availablePort()
        let releaseWorkDir = root.appendingPathComponent("local-release", isDirectory: true)
        let releasesURL = URL(string: "http://127.0.0.1:\(releasePort)/releases")!

        setEnvironment([
            "LOLABUNNY_UPDATE_RELEASES_URL": releasesURL.absoluteString,
            "LOLABUNNY_UPDATE_RELEASE_TAG": "latest",
        ])

        let localReleaseServer = try LocalReleaseServer.start(
            port: releasePort,
            workDir: releaseWorkDir,
            seedBinary: binary,
            version: version
        )
        try await waitForLocalReleaseServer(releasesURL: releasesURL)
        return localReleaseServer
    }

    func uploadRelease(version: String, binary: URL) async throws {
        let uploadURL = try XCTUnwrap(URL(string: "\(Config.Server.updateReleasesURL!.absoluteString)/upload/\(version)"))
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = try Data(contentsOf: binary)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw E2EError("release upload failed: \(response) \(body)")
        }
    }

    private func waitForLocalReleaseServer(releasesURL: URL) async throws {
        let deadline = Date().addingTimeInterval(8)
        var lastObservation = "timeout"

        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: releasesURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return
                }
                if let http = response as? HTTPURLResponse {
                    lastObservation = "status \(http.statusCode)"
                } else {
                    lastObservation = "non-HTTP response"
                }
            } catch {
                lastObservation = error.localizedDescription
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw E2EError("local release widget-server did not become ready: \(lastObservation)")
    }

    func serverVersion(_ binary: URL) throws -> String {
        try run(
            binary,
            arguments: ["--version"],
            currentDirectory: Self.repoRoot()
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func publishRelease(
        version: String,
        binary: URL,
        corruptChecksum: Bool = false
    ) throws {
        let fm = FileManager.default
        let archiveName = "\(Config.serverExecutableName)-\(version)-darwin-\(Self.architectureLabel()).tar.gz"
        let downloadDir = releasesDir
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let packageDir = root
            .appendingPathComponent("package-\(version)", isDirectory: true)
        if fm.fileExists(atPath: packageDir.path) {
            try fm.removeItem(at: packageDir)
        }
        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let packagedBinary = packageDir.appendingPathComponent(Config.serverExecutableName)
        try fm.copyItem(at: binary, to: packagedBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packagedBinary.path)
        try "\(version)\n".write(
            to: packageDir.appendingPathComponent(".version"),
            atomically: true,
            encoding: .utf8
        )

        let checksum: String
        if corruptChecksum {
            checksum = String(repeating: "0", count: 64)
        } else if let actualChecksum = ServerArchiveUtils.sha256Hex(for: packagedBinary) {
            checksum = actualChecksum
        } else {
            throw E2EError("failed to checksum packaged widget-server")
        }
        try "\(checksum) *\(Config.serverExecutableName)\n".write(
            to: packageDir.appendingPathComponent("\(Config.serverExecutableName).sha256"),
            atomically: true,
            encoding: .utf8
        )

        let archiveURL = downloadDir.appendingPathComponent(archiveName)
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }
        _ = try run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "czf", archiveURL.path,
                "-C", packageDir.path,
                Config.serverExecutableName,
                "\(Config.serverExecutableName).sha256",
                ".version",
            ]
        )
        try "/releases/tag/\(version)\n".write(
            to: releasesDir.appendingPathComponent("latest"),
            atomically: true,
            encoding: .utf8
        )
    }

    func launchServer(_ binary: URL) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "serve",
            "--port", "\(port)",
            "--address", "127.0.0.1",
            "--history-enabled", "false",
            "--volume-path", volumeDir.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "XDG_DATA_HOME": dataRoot.path,
            "TMPDIR": root.path,
        ]) { _, new in new }
        process.currentDirectoryURL = try Self.repoRoot()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    func terminate(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        process.waitUntilExit()
    }

    func activeBinary(version: String) -> URL {
        dataRoot
            .appendingPathComponent("servers", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(Config.serverExecutableName)
    }

    func lockedBinary(version: String) -> URL {
        dataRoot
            .appendingPathComponent("servers", isDirectory: true)
            .appendingPathComponent("\(version).locked", isDirectory: true)
            .appendingPathComponent(Config.serverExecutableName)
    }

    func waitForHealth(_ expectedVersion: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        var lastObservation = "timeout"
        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: Config.serverBaseURL.appendingPathComponent("health"))
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 200,
                   body == expectedVersion {
                    return
                }
                if let http = response as? HTTPURLResponse {
                    lastObservation = "status \(http.statusCode), body '\(body)'"
                } else {
                    lastObservation = "non-HTTP response"
                }
            } catch {
                lastObservation = error.localizedDescription
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw E2EError("widget-server health did not become ready for version \(expectedVersion): \(lastObservation)")
    }

    func serverHealthStatus() async throws -> (code: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: Config.serverBaseURL.appendingPathComponent("health"))
        guard let http = response as? HTTPURLResponse else {
            throw E2EError("widget-server health returned non-HTTP response")
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (http.statusCode, body)
    }

    func redirectLocation(for command: String) async throws -> String {
        var components = URLComponents(url: Config.serverBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cmd", value: command)]
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        let (_, response) = try await session.data(for: URLRequest(url: components.url!))
        guard let http = response as? HTTPURLResponse,
              (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else {
            throw E2EError("expected redirect response")
        }
        return location
    }

    @discardableResult
    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw E2EError("process failed: \(executable.path) \(arguments.joined(separator: " "))\n\(output)\(error)")
        }
        return output
    }

    private func setEnvironment(_ values: [String: String]) {
        for (key, value) in values {
            if previousEnvironment[key] == nil {
                previousEnvironment[key] = ProcessInfo.processInfo.environment[key]
            }
            setenv(key, value, 1)
        }
    }

    private func restoreEnvironment() {
        for (key, value) in previousEnvironment {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    private static func repoRoot() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
        while current.path != "/" {
            let candidate = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw E2EError("could not locate repository root")
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw E2EError("socket failed")
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
            throw E2EError("bind failed")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw E2EError("getsockname failed")
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    private static func architectureLabel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { rebound in
                String(cString: rebound)
            }
        }
        switch machine {
        case "arm64", "aarch64":
            return "arm64"
        case "x86_64", "amd64":
            return "x86_64"
        default:
            return machine
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct E2EError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
