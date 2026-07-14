import Foundation
import CryptoKit
import SWCompression

enum ServerArchiveUtils {
    static func sha256Hex(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            log("failed to read \(fileURL.path) for sha256")
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func parseExpectedSHA256(contents: String, archiveName: String) -> String? {
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
            let normalized = fileField
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "*", with: "")
            if normalized.hasSuffix(archiveName) {
                return hash
            }
        }
        return nil
    }

    static func verifyExtractedBinary(
        binaryURL: URL,
        checksumURL: URL
    ) -> Bool {
        guard let checksumContents = try? String(contentsOf: checksumURL, encoding: .utf8) else {
            log("failed reading extracted checksum file \(checksumURL.path)")
            return false
        }
        let binaryName = binaryURL.lastPathComponent
        guard
            let expected = parseExpectedSHA256(contents: checksumContents, archiveName: binaryName)
        else {
            log("checksum file did not include a valid hash for \(binaryName)")
            return false
        }
        guard let actual = sha256Hex(for: binaryURL) else {
            return false
        }
        guard expected == actual else {
            log("checksum mismatch for \(binaryName): expected \(expected), got \(actual)")
            return false
        }
        return true
    }

    static func canLaunchBinary(_ binaryURL: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return false
        }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            log("binary not launchable (\(binaryURL.path)): \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            log("binary version probe failed (\(binaryURL.path)), exit=\(proc.terminationStatus)")
            return false
        }
        return true
    }

    static func detectedVersion(from binaryURL: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return nil
        }
        guard let output = versionProbeOutput(for: binaryURL) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let range = trimmed.range(
            of: #"v?\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[range])
            return token.hasPrefix("v") ? token : "v\(token)"
        }
        return nil
    }

    static func prepareDownloadedArchive(
        archiveURL: URL,
        extractedDir: URL,
        binaryName: String,
        requestedVersion: String,
        rollingLatestMode: Bool
    ) -> (resolvedVersion: String, extractedBinary: URL)? {
        guard extractArchive(archiveURL, to: extractedDir) else {
            return nil
        }

        let extractedBinary = extractedDir.appendingPathComponent(binaryName)
        let extractedChecksum = extractedDir.appendingPathComponent("\(binaryName).sha256")
        guard verifyExtractedBinary(binaryURL: extractedBinary, checksumURL: extractedChecksum) else {
            log("downloaded widget-server failed checksum verification")
            return nil
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)
        } catch {
            log("failed to set executable permissions: \(error.localizedDescription)")
        }

        guard canLaunchBinary(extractedBinary) else {
            log("downloaded widget-server binary is not runnable for current architecture")
            return nil
        }

        if rollingLatestMode {
            guard let detected = detectedVersion(from: extractedBinary) else {
                log("failed to resolve widget-server version from downloaded latest archive")
                return nil
            }
            return (detected, extractedBinary)
        }
        return (requestedVersion, extractedBinary)
    }

    static func archiveEntryOutputURL(baseDir: URL, entryName: String) -> URL? {
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

    static func extractArchive(_ archiveURL: URL, to destinationDir: URL) -> Bool {
        let fm = FileManager.default
        do {
            let compressedData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
            let tarData = try GzipArchive.unarchive(archive: compressedData)
            let entries = try TarContainer.open(container: tarData)

            for entry in entries {
                guard
                    let outputURL = archiveEntryOutputURL(
                        baseDir: destinationDir,
                        entryName: entry.info.name
                    )
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
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: outputURL, options: .atomic)
                    if let permissions = entry.info.permissions {
                        try fm.setAttributes(
                            [.posixPermissions: Int(permissions.rawValue)],
                            ofItemAtPath: outputURL.path
                        )
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

    private static func versionProbeOutput(for binaryURL: URL) -> String? {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--version"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            log("binary version detection failed (\(binaryURL.path)): \(error.localizedDescription)")
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            log("binary version detection failed (\(binaryURL.path)), exit=\(proc.terminationStatus)")
            return nil
        }

        let outputData = out.fileHandleForReading.readDataToEndOfFile()
            + err.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)
    }
}
