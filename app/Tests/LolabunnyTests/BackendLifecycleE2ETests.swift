import Darwin
import Foundation
import Testing
@testable import Lolabunny

@MainActor
@Suite(.serialized)
struct BackendLifecycleE2ETests {
    @Test func backendServerHandlesHealthRedirectsAndBlobs() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildBackendBinary()
            let version = try sandbox.backendVersion(binary)
            let process = try sandbox.launchBackend(binary)
            defer { sandbox.terminate(process) }

            try await sandbox.waitForHealth(version)

            let redirect = try await sandbox.redirectLocation(for: "lower MiXeD Value")
            #expect(redirect == "data:text/plain;charset=utf-8,mixed%20value")

            let blobID = try await sandbox.createBlob("hello blob")
            let blob = try await sandbox.readBlob(id: blobID)
            #expect(blob == "hello blob")
        }
    }

    @Test func bootstrapInstallsBackendFromMockRelease() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildBackendBinary()
            try sandbox.publishRelease(version: "v1.0.0", binary: binary)

            let app = AppDelegate()
            let installed = await app.bootstrapBackendFromDistribution(
                requiredMajor: "1",
                downloader: sandbox.downloader
            )

            #expect(installed?.version == "v1.0.0")
            #expect(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: "v1.0.0").path))
            #expect(app.configuredBackendVersion() == "v1.0.0")
        }
    }

    @Test func stagedUpdateActivatesCompatibleRelease() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildBackendBinary()
            let app = AppDelegate()

            try sandbox.publishRelease(version: "v1.0.0", binary: binary)
            let installed = await app.bootstrapBackendFromDistribution(
                requiredMajor: "1",
                downloader: sandbox.downloader
            )
            #expect(installed?.version == "v1.0.0")

            try sandbox.publishRelease(version: "v1.1.0", binary: binary)
            let release = try #require(await app.fetchLatestRelease())
            let staged = await app.downloadAndStageBackend(
                version: "v1.1.0",
                archiveURL: release.archiveURL,
                downloader: sandbox.downloader
            )

            #expect(staged?.version == "v1.1.0")
            #expect(FileManager.default.isExecutableFile(atPath: sandbox.lockedBinary(version: "v1.1.0").path))
            #expect(app.activateDownloadedBackend(version: "v1.1.0"))
            #expect(app.configuredBackendVersion() == "v1.1.0")
            #expect(FileManager.default.isExecutableFile(atPath: sandbox.activeBinary(version: "v1.1.0").path))
        }
    }

    @Test func corruptReleaseDoesNotInstall() async throws {
        try await withE2ESandbox { sandbox in
            let binary = try sandbox.buildBackendBinary()
            try sandbox.publishRelease(version: "v1.2.0", binary: binary, corruptChecksum: true)

            let app = AppDelegate()
            let installed = await app.bootstrapBackendFromDistribution(
                requiredMajor: "1",
                downloader: sandbox.downloader
            )

            #expect(installed == nil)
            #expect(app.configuredBackendVersion() == nil)
            #expect(!FileManager.default.fileExists(atPath: sandbox.activeBinary(version: "v1.2.0").path))
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
    let downloader = LocalhostBackendDownloader(streamDelayMillis: 0)

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
            "LOLABUNNY_BACKEND_ADDRESS": "127.0.0.1",
            "LOLABUNNY_BACKEND_PORT": "\(port)",
            "LOLABUNNY_BACKEND_RUNTIME_DIR": runtimeDir.path,
            "LOLABUNNY_BACKEND_VERSION": "v1.0.0",
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

    func buildBackendBinary() throws -> URL {
        let repoRoot = try Self.repoRoot()
        let packagePath = repoRoot.appendingPathComponent("app-server", isDirectory: true)
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
                "--package-path", packagePath.path,
                "--scratch-path", scratchPath.path,
                "--configuration", "debug",
                "--product", "lolabunny",
            ],
            environment: buildEnvironment,
            currentDirectory: repoRoot
        )
        let binPath = try run(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swift", "build",
                "--disable-sandbox",
                "--package-path", packagePath.path,
                "--scratch-path", scratchPath.path,
                "--configuration", "debug",
                "--product", "lolabunny",
                "--show-bin-path",
            ],
            environment: buildEnvironment,
            currentDirectory: repoRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: binPath).appendingPathComponent("lolabunny")
    }

    func backendVersion(_ binary: URL) throws -> String {
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
        let archiveName = "\(Config.appName)-\(version)-darwin-\(Self.architectureLabel()).tar.gz"
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

        let packagedBinary = packageDir.appendingPathComponent(Config.appName)
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
        } else if let actualChecksum = BackendArchiveUtils.sha256Hex(for: packagedBinary) {
            checksum = actualChecksum
        } else {
            throw E2EError("failed to checksum packaged backend")
        }
        try "\(checksum) *\(Config.appName)\n".write(
            to: packageDir.appendingPathComponent("\(Config.appName).sha256"),
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
                Config.appName,
                "\(Config.appName).sha256",
                ".version",
            ]
        )
        try "/releases/tag/\(version)\n".write(
            to: releasesDir.appendingPathComponent("latest"),
            atomically: true,
            encoding: .utf8
        )
    }

    func launchBackend(_ binary: URL) throws -> Process {
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
            .appendingPathComponent("backends", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(Config.appName)
    }

    func lockedBinary(version: String) -> URL {
        dataRoot
            .appendingPathComponent("backends", isDirectory: true)
            .appendingPathComponent("\(version).locked", isDirectory: true)
            .appendingPathComponent(Config.appName)
    }

    func waitForHealth(_ expectedVersion: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        var lastObservation = "timeout"
        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: Config.backendBaseURL.appendingPathComponent("health"))
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
        throw E2EError("backend health did not become ready for version \(expectedVersion): \(lastObservation)")
    }

    func redirectLocation(for command: String) async throws -> String {
        var components = URLComponents(url: Config.backendBaseURL, resolvingAgainstBaseURL: false)!
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

    func createBlob(_ text: String) async throws -> String {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("blob"))
        request.httpMethod = "POST"
        request.httpBody = Data(text.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else {
            throw E2EError("blob create failed")
        }
        return String(body.split(separator: "\t").first ?? "")
    }

    func readBlob(id: String) async throws -> String {
        let url = Config.backendBaseURL
            .appendingPathComponent("blob")
            .appendingPathComponent(id)
            .appendingPathComponent("raw")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else {
            throw E2EError("blob read failed")
        }
        return body
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
            let candidate = current.appendingPathComponent("app-server/Package.swift")
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
