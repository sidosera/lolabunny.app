import Darwin
import Foundation
import LolabunnyDistributionSupport

@main
enum LolabunnyMonolithApp {
    static func main() async throws {
        let runner = try BundledRunner(arguments: Array(CommandLine.arguments.dropFirst()))
        runner.installSignalHandlers()
        try await runner.run()
    }
}

private final class BundledRunner {
    private let rootDir: URL
    private let host: String
    private let releasePort: UInt16
    private let serverPort: UInt16
    private let version: String
    private let scratchPath: URL
    private let runtimeDir: URL
    private let releaseWorkDir: URL
    private let releaseLog: URL
    private let serverLog: URL
    private let appLog: URL
    private let appPIDFile: URL
    private let serverPIDFile: URL
    private let appSessionDir: URL
    private let appTmpDir: URL
    private let appDataDir: URL
    private let appRuntimeDir: URL
    private let appVolumeDir: URL

    private var localReleaseServer: LocalReleaseServer?
    private var serverProcess: Process?
    private var appProcess: Process?
    private var signalSources: [DispatchSourceSignal] = []

    init(arguments: [String]) throws {
        let options = BundledOptions(arguments: arguments)
        rootDir = try Self.locateRepositoryRoot()
        host = options.host
        releasePort = options.releasePort
        serverPort = try options.serverPort ?? Self.availablePort()
        version = options.version
        scratchPath = options.scratchPath ?? rootDir
            .appendingPathComponent(".build/swiftpm/monolith-app", isDirectory: true)
        runtimeDir = options.runtimeDir ?? rootDir
            .appendingPathComponent(".build/monolith-app", isDirectory: true)
        releaseWorkDir = runtimeDir.appendingPathComponent("release", isDirectory: true)
        releaseLog = runtimeDir.appendingPathComponent("release.log")
        serverLog = runtimeDir.appendingPathComponent("widget-server.log")
        appLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lolabunny.log")
        appPIDFile = runtimeDir.appendingPathComponent("widget.pid")
        serverPIDFile = runtimeDir.appendingPathComponent("widget-server.pid")
        appSessionDir = runtimeDir.appendingPathComponent("widget-session", isDirectory: true)
        appTmpDir = appSessionDir.appendingPathComponent("tmp", isDirectory: true)
        appDataDir = appSessionDir.appendingPathComponent("data", isDirectory: true)
        appRuntimeDir = appSessionDir.appendingPathComponent("runtime", isDirectory: true)
        appVolumeDir = appSessionDir.appendingPathComponent("volume", isDirectory: true)
    }

    func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.cleanup()
                exit(sig == SIGINT ? 130 : 143)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func run() async throws {
        try prepareWorkspace()
        defer { cleanup() }

        try build(product: "widget-server")
        try build(product: "widget")

        let binDir = try showBinPath(product: "widget")
        let serverBinary = binDir.appendingPathComponent("widget-server")
        let appBinary = binDir.appendingPathComponent("widget")

        let releasesURL = URL(string: "http://\(host):\(releasePort)/releases")!
        let archiveURL = releasesURL
            .appendingPathComponent("download")
            .appendingPathComponent(version)
            .appendingPathComponent("lolabunny-server@\(version)-darwin-\(Self.architectureLabel()).tar.gz")

        try startLocalReleaseServer(serverBinary: serverBinary, releasesURL: releasesURL)
        try await waitForLocalReleaseServer(releasesURL: releasesURL)
        _ = try await httpBody(from: archiveURL)

        let serverURL = URL(string: "http://\(host):\(serverPort)")!
        try startServer(binary: serverBinary)
        try await waitForServer(serverURL: serverURL)

        print("Lolabunny monolith runtime running")
        print("  releases: \(releasesURL.absoluteString)")
        print("  seeded:   \(version)")
        print("  archive:  \(archiveURL.absoluteString)")
        print("  release:    in-process log=\(releaseLog.path)")
        print("  widget-server:   pid=\(serverProcess?.processIdentifier ?? -1) url=\(serverURL.absoluteString) log=\(serverLog.path)")
        print("  widget data: \(appDataDir.path)")
        print("  widget log:  \(appLog.path)")
        print()
        print("Upload another widget-server:")
        print("  curl -X PUT --data-binary @/path/to/widget-server '\(releasesURL.absoluteString)/upload/v1.2.3'")
        print()
        print("Launching the menu-bar widget. This command stays running until you quit the widget or press Ctrl-C.")
        print()
        fflush(stdout)

        try startApp(binary: appBinary, releasesURL: releasesURL)
        appProcess?.waitUntilExit()
    }

    private func prepareWorkspace() throws {
        let fm = FileManager.default
        for dir in [runtimeDir, releaseWorkDir, appTmpDir, appDataDir, appRuntimeDir, appVolumeDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try killPIDFile(appPIDFile, label: "widget")
        try killPIDFile(serverPIDFile, label: "widget-server")
        try killPIDFile(appRuntimeDir.appendingPathComponent("pid"), label: "managed widget-server")
    }

    private func build(product: String) throws {
        log("Building \(product)...")
        try run(
            "/usr/bin/env",
            arguments: [
                "swift", "build",
                "--package-path", rootDir.path,
                "--scratch-path", scratchPath.path,
                "--configuration", "debug",
                "--product", product,
            ]
        )
    }

    private func showBinPath(product: String) throws -> URL {
        let output = try run(
            "/usr/bin/env",
            arguments: [
                "swift", "build",
                "--package-path", rootDir.path,
                "--scratch-path", scratchPath.path,
                "--configuration", "debug",
                "--product", product,
                "--show-bin-path",
            ],
            captureOutput: true
        )
        return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }

    private func startLocalReleaseServer(serverBinary: URL, releasesURL: URL) throws {
        log("Starting fake release widget-server on \(releasesURL.absoluteString)...")
        try resetLog(releaseLog)
        let logURL = releaseLog
        localReleaseServer = try LocalReleaseServer.start(
            host: host,
            port: releasePort,
            workDir: releaseWorkDir,
            seedBinary: serverBinary,
            version: version
        ) { error in
            let line = "local release widget-server failed: \(error)\n"
            if let data = line.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
                _ = try? handle.close()
            }
        }
    }

    private func startServer(binary: URL) throws {
        let serverURL = "http://\(host):\(serverPort)"
        log("Starting bundled widget-server on \(serverURL)...")
        try resetLog(serverLog)
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "serve",
            "--address", host,
            "--port", "\(serverPort)",
            "--history-enabled", "false",
            "--volume-path", appVolumeDir.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TMPDIR": appTmpDir.path + "/",
            "XDG_DATA_HOME": appDataDir.path,
        ]) { _, new in new }
        process.standardOutput = try logHandle(serverLog)
        process.standardError = process.standardOutput
        try process.run()
        serverProcess = process
        try "\(process.processIdentifier)\n".write(to: serverPIDFile, atomically: true, encoding: .utf8)
    }

    private func startApp(binary: URL, releasesURL: URL) throws {
        let process = Process()
        process.executableURL = binary
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LOLABUNNY_SERVER_VERSION": version,
            "LOLABUNNY_SERVER_ADDRESS": host,
            "LOLABUNNY_SERVER_PORT": "\(serverPort)",
            "LOLABUNNY_SERVER_EXTERNALLY_MANAGED": "true",
            "LOLABUNNY_SERVER_RUNTIME_DIR": appRuntimeDir.path,
            "LOLABUNNY_DATA_ROOT": appDataDir.path,
            "LOLABUNNY_VOLUME_PATH": appVolumeDir.path,
            "TMPDIR": appTmpDir.path + "/",
            "LOLABUNNY_UPDATE_RELEASES_URL": releasesURL.absoluteString,
            "LOLABUNNY_UPDATE_RELEASE_TAG": "latest",
        ]) { _, new in new }
        try process.run()
        appProcess = process
        try "\(process.processIdentifier)\n".write(to: appPIDFile, atomically: true, encoding: .utf8)
    }

    private func waitForLocalReleaseServer(releasesURL: URL) async throws {
        let latestURL = releasesURL.appendingPathComponent("latest")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if (try? await httpBody(from: latestURL).trimmingCharacters(in: .whitespacesAndNewlines)) == version {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BundledRuntimeError("local release widget-server did not publish \(version) at \(latestURL.absoluteString)\n\(try logExcerpt(releaseLog))")
    }

    private func waitForServer(serverURL: URL) async throws {
        let healthURL = serverURL.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try ensureRunning(serverProcess, label: "Bundled widget-server", log: serverLog)
            if (try? await httpBody(from: healthURL)).isSome {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BundledRuntimeError("bundled widget-server did not become ready at \(healthURL.absoluteString)\n\(try logExcerpt(serverLog))")
    }

    private func httpBody(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BundledRuntimeError("request failed \(http.statusCode): \(url.absoluteString)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func ensureRunning(_ process: Process?, label: String, log: URL) throws {
        guard let process, process.isRunning else {
            throw BundledRuntimeError("\(label) exited before becoming ready\n\(try logExcerpt(log))")
        }
    }

    private func killPIDFile(_ file: URL, label: String) throws {
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            try? FileManager.default.removeItem(at: file)
            return
        }

        if kill(pid, 0) == 0 {
            log("Stopping previous \(label) pid=\(pid)")
            kill(pid, SIGTERM)
            for _ in 0..<30 {
                if kill(pid, 0) != 0 {
                    break
                }
                usleep(100_000)
            }
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func cleanup() {
        appProcess?.terminate()
        serverProcess?.terminate()
        try? FileManager.default.removeItem(at: appPIDFile)
        try? FileManager.default.removeItem(at: serverPIDFile)
    }

    @discardableResult
    private func run(
        _ executable: String,
        arguments: [String],
        captureOutput: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = rootDir

        let stdout = Pipe()
        let stderr = Pipe()
        if captureOutput {
            process.standardOutput = stdout
            process.standardError = stderr
        }

        try process.run()
        process.waitUntilExit()

        let output = captureOutput ? String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" : ""
        let error = captureOutput ? String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" : ""
        guard process.terminationStatus == 0 else {
            throw BundledRuntimeError("command failed: \(executable) \(arguments.joined(separator: " "))\n\(output)\(error)")
        }
        return output
    }

    private func resetLog(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private func logHandle(_ url: URL) throws -> FileHandle {
        try FileHandle(forWritingTo: url)
    }

    private func logExcerpt(_ url: URL) throws -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8), !contents.isEmpty else {
            return "(empty log: \(url.path))"
        }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(160)
            .joined(separator: "\n")
    }

    private func log(_ message: String) {
        print("[monolith-app] \(message)")
        fflush(stdout)
    }

    private static func locateRepositoryRoot() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
        while current.path != "/" {
            let candidate = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw BundledRuntimeError("could not locate repository root")
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BundledRuntimeError("socket failed")
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw BundledRuntimeError("bind failed")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw BundledRuntimeError("getsockname failed")
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    private static func architectureLabel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
}

private struct BundledOptions {
    var host = "127.0.0.1"
    var releasePort: UInt16 = 18086
    var serverPort: UInt16?
    var version = "v1.0.0-local"
    var scratchPath: URL?
    var runtimeDir: URL?

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host":
                host = Self.value(after: argument, in: arguments, index: &index) ?? host
            case "--release-port":
                if let raw = Self.value(after: argument, in: arguments, index: &index) {
                    releasePort = UInt16(raw) ?? releasePort
                }
            case "--widget-server-port":
                if let raw = Self.value(after: argument, in: arguments, index: &index) {
                    serverPort = UInt16(raw)
                }
            case "--version":
                version = Self.value(after: argument, in: arguments, index: &index) ?? version
            case "--scratch-path":
                if let raw = Self.value(after: argument, in: arguments, index: &index) {
                    scratchPath = URL(fileURLWithPath: raw, isDirectory: true)
                }
            case "--runtime-dir":
                if let raw = Self.value(after: argument, in: arguments, index: &index) {
                    runtimeDir = URL(fileURLWithPath: raw, isDirectory: true)
                }
            case "--help", "-h":
                Self.printHelp()
                exit(0)
            default:
                if !argument.hasPrefix("-") {
                    version = argument
                }
                index += 1
            }
        }
    }

    private static func value(after flag: String, in arguments: [String], index: inout Int) -> String? {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            index += 1
            return nil
        }
        index += 2
        return arguments[valueIndex]
    }

    private static func printHelp() {
        print("""
        Usage: monolith-app [VERSION] [options]

        Options:
          --host HOST             Bind host. Default: 127.0.0.1.
          --release-port PORT       Fake release widget-server port. Default: 18086.
          --widget-server-port PORT      Bundled widget-server port. Default: random free port.
          --version VERSION       Seeded fake release version. Default: v1.0.0-local.
          --scratch-path PATH     SwiftPM scratch path.
          --runtime-dir PATH      Runtime/log directory.
        """)
    }
}

private struct BundledRuntimeError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private extension Optional {
    var isSome: Bool {
        self != nil
    }
}
