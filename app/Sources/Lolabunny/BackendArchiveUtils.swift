import Foundation
import CryptoKit
import SWCompression

enum BackendArchiveUtils {
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

    static func verifyDownloadedArchive(
        archiveURL: URL,
        checksumURL: URL,
        archiveName: String
    ) -> Bool {
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
}
