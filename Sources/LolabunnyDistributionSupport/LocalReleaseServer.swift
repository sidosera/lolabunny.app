import Darwin
import Foundation
import LolabunnyWidgetServerCore

private enum ReleaseDefaults {
    static let host = "127.0.0.1"
    static let port: UInt16 = 18086
    static let basePath = "/releases"
    static let serverExecutableName = "widget-server"
}

public final class LocalReleaseServer {
    public let releasesURL: String

    private let server: LocalReleaseHTTPServer

    private init(server: LocalReleaseHTTPServer) {
        self.server = server
        releasesURL = server.releasesURL
    }

    public static func start(
        host: String = "127.0.0.1",
        port: UInt16 = 18086,
        basePath: String = "/releases",
        workDir: URL,
        seedBinary: URL? = nil,
        version: String? = nil,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) throws -> LocalReleaseServer {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let store = ReleaseStore(workDir: workDir)
        if let seedBinary {
            _ = try store.publish(
                binary: seedBinary,
                version: version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? version!
                    : "v0.0.0-local"
            )
        }

        let server = LocalReleaseHTTPServer(
            host: host,
            port: port,
            basePath: basePath.hasPrefix("/") ? basePath : "/" + basePath,
            store: store
        )
        let localReleaseServer = LocalReleaseServer(server: server)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run()
            } catch {
                onError(error)
            }
        }

        return localReleaseServer
    }
}

private struct ReleaseArtifact {
    let version: String
    let archiveName: String
    let archiveURL: URL
    let archiveData: Data

    static func package(binary: URL, version: String, workDir: URL) throws -> ReleaseArtifact {
        let fm = FileManager.default
        let architecture = architectureLabel()
        let archiveName = "\(ReleaseDefaults.serverExecutableName)-\(version)-darwin-\(architecture).tar.gz"
        let packageDir = workDir.appendingPathComponent("release-package-\(safePathComponent(version))", isDirectory: true)
        let archiveDir = workDir.appendingPathComponent("archives", isDirectory: true)
        let archiveURL = archiveDir.appendingPathComponent(archiveName)

        if fm.fileExists(atPath: packageDir.path) {
            try fm.removeItem(at: packageDir)
        }
        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let packagedBinary = packageDir.appendingPathComponent(ReleaseDefaults.serverExecutableName)
        if fm.fileExists(atPath: packagedBinary.path) {
            try fm.removeItem(at: packagedBinary)
        }
        try fm.copyItem(at: binary, to: packagedBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packagedBinary.path)

        let checksum = try checksumSHA256(file: packagedBinary)
        try "\(checksum) *\(ReleaseDefaults.serverExecutableName)\n".write(
            to: packageDir.appendingPathComponent("\(ReleaseDefaults.serverExecutableName).sha256"),
            atomically: true,
            encoding: .utf8
        )
        try "\(version)\n".write(
            to: packageDir.appendingPathComponent(".version"),
            atomically: true,
            encoding: .utf8
        )

        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }
        _ = try run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "czf", archiveURL.path,
                "-C", packageDir.path,
                ReleaseDefaults.serverExecutableName,
                "\(ReleaseDefaults.serverExecutableName).sha256",
                ".version",
            ],
            currentDirectory: workDir
        )

        return ReleaseArtifact(
            version: version,
            archiveName: archiveName,
            archiveURL: archiveURL,
            archiveData: try Data(contentsOf: archiveURL)
        )
    }

    private static func architectureLabel() -> String {
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) { pointer in
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

private func safePathComponent(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_+"))
    let scalars = raw.unicodeScalars.map { scalar in
        allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    return value.isEmpty ? "release" : value
}

private final class ReleaseStore {
    private let workDir: URL
    private var releases: [String: ReleaseArtifact] = [:]
    private var latestVersion: String?

    init(workDir: URL) {
        self.workDir = workDir
    }

    var latest: ReleaseArtifact? {
        guard let latestVersion else {
            return nil
        }
        return releases[latestVersion]
    }

    func artifact(version: String) -> ReleaseArtifact? {
        releases[version]
    }

    func allVersions() -> [String] {
        releases.keys.sorted()
    }

    @discardableResult
    func publish(binary: URL, version: String) throws -> ReleaseArtifact {
        let artifact = try ReleaseArtifact.package(
            binary: binary,
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            workDir: workDir
        )
        releases[artifact.version] = artifact
        latestVersion = artifact.version
        return artifact
    }

    @discardableResult
    func publish(data: Data, version: String) throws -> ReleaseArtifact {
        let uploadDir = workDir.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        let binary = uploadDir.appendingPathComponent("widget-server-\(safePathComponent(version))")
        try data.write(to: binary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return try publish(binary: binary, version: version)
    }
}

private final class LocalReleaseHTTPServer: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let basePath: String
    private let store: ReleaseStore
    private let server: SimpleHTTPServer

    var releasesURL: String {
        "http://\(host):\(port)\(basePath)"
    }

    init(host: String, port: UInt16, basePath: String, store: ReleaseStore) {
        self.host = host
        self.port = port
        self.basePath = basePath
        self.store = store
        server = SimpleHTTPServer(address: host, port: port) { request in
            do {
                return try Self.response(for: request, host: host, port: port, basePath: basePath, store: store)
            } catch {
                return .text("bad request\n", statusCode: 400, reason: "Bad Request")
            }
        }
    }

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        try server.run()
    }

    private static func response(
        for request: HTTPRequest,
        host: String,
        port: UInt16,
        basePath: String,
        store: ReleaseStore
    ) throws -> HTTPResponse {
        let path = request.path
        let releasesURL = "http://\(host):\(port)\(basePath)"

        if request.method == "PUT", let version = uploadVersion(from: path) {
            let artifact = try store.publish(data: request.body, version: version)
            return textResponse(
                201,
                "Created",
                "published \(artifact.version)\n\(releasesURL)/download/\(artifact.version)/\(artifact.archiveName)\n"
            )
        }

        if path == basePath || path == basePath + "/" {
            return textResponse(200, "OK", store.allVersions().joined(separator: "\n") + "\n")
        }

        if let range = path.range(of: "/releases/latest") {
            guard let artifact = store.latest else {
            return textResponse(404, "Not Found", "no releases published\n")
        }
            let releasesPath = String(path[..<range.lowerBound]) + "/releases"
            let location = "http://\(host):\(port)\(releasesPath)/tag/\(artifact.version)"
            return HTTPResponse(
                statusCode: 302,
                reason: "Found",
                headers: ["Location": location],
                body: Data()
            )
        }

        if let version = releaseTag(from: path), let artifact = store.artifact(version: version) {
            return textResponse(200, "OK", "\(artifact.version)\n")
        }

        if let range = path.range(of: "/releases/download/") {
            let suffix = path[range.upperBound...]
            let components = suffix.split(separator: "/").map(String.init)
            if components.count >= 2,
               let artifact = store.artifact(version: components[0]),
               components.last == artifact.archiveName {
                return HTTPResponse(
                    statusCode: 200,
                    reason: "OK",
                    headers: ["Content-Type": "application/gzip"],
                    body: artifact.archiveData
                )
            }
        }

        return textResponse(404, "Not Found", "not found\n")
    }

    private static func uploadVersion(from path: String) -> String? {
        guard let range = path.range(of: "/releases/upload/") else {
            return nil
        }
        let version = String(path[range.upperBound...])
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init)?
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version?.isEmpty == false ? version : nil
    }

    private static func releaseTag(from path: String) -> String? {
        guard let range = path.range(of: "/releases/tag/") else {
            return nil
        }
        let version = String(path[range.upperBound...])
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init)?
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version?.isEmpty == false ? version : nil
    }

    private static func textResponse(_ status: Int, _ reason: String, _ text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            reason: reason,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }
}

private func checksumSHA256(file: URL) throws -> String {
    let output = try run(
        URL(fileURLWithPath: "/usr/bin/shasum"),
        arguments: ["-a", "256", file.path],
        currentDirectory: file.deletingLastPathComponent()
    )
    guard let checksum = output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
          checksum.count == 64 else {
        throw ReleaseServerError("failed to parse shasum output for \(file.path)")
    }
    return String(checksum)
}

@discardableResult
private func run(
    _ executable: URL,
    arguments: [String],
    environment: [String: String] = [:],
    currentDirectory: URL
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
        throw ReleaseServerError("process failed: \(executable.path) \(arguments.joined(separator: " "))\n\(output)\(error)")
    }
    return output
}

private struct ReleaseServerError: LocalizedError, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? {
        description
    }
}
