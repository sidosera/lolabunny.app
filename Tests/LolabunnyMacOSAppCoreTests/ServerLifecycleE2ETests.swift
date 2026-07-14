import Darwin
import Foundation
import XCTest

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
            XCTAssertEqual(redirect, "data:text/plain;charset=utf-8,mixed%20value")
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
    let volumeDir: URL
    let port: UInt16

    init() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lolabunny-e2e-\(UUID().uuidString)", isDirectory: true)
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        volumeDir = root.appendingPathComponent("volume", isDirectory: true)
        port = try Self.availablePort()

        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: volumeDir, withIntermediateDirectories: true)
    }

    func cleanup() {
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
                "--product", "lolabunny-server",
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
                "--product", "lolabunny-server",
                "--show-bin-path",
            ],
            environment: buildEnvironment,
            currentDirectory: repoRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: binPath).appendingPathComponent("lolabunny-server")
    }

    func serverVersion(_ binary: URL) throws -> String {
        try run(
            binary,
            arguments: ["--version"],
            currentDirectory: Self.repoRoot()
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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

    func waitForHealth(_ expectedVersion: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        var lastObservation = "timeout"
        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: serverBaseURL.appendingPathComponent("health"))
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
        throw E2EError("lolabunny-server health did not become ready for version \(expectedVersion): \(lastObservation)")
    }

    func redirectLocation(for command: String) async throws -> String {
        var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false)!
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

    private var serverBaseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw E2EError("bind failed")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw E2EError("getsockname failed")
        }
        return UInt16(bigEndian: bound.sin_port)
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
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private struct E2EError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
