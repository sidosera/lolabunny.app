import CryptoKit
import Foundation
import Security

final class BlobStore {
    private let baseDirectory: URL

    init(volumePath: String?) {
        if let volumePath,
           !volumePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseDirectory = URL(
                fileURLWithPath: (volumePath as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            baseDirectory = Paths.defaultVolumeDirectory
        }
    }

    func put(namespace: String, content: Data) throws -> String {
        let rawID = try Self.generateID()
        let encrypted = try Self.encrypt(id: rawID, plaintext: content)
        let fileID = Self.fileID(rawID)
        let directory = baseDirectory.appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encrypted.write(to: directory.appendingPathComponent(fileID), options: [.atomic])
        return "0\(rawID)"
    }

    static func get(namespace: String, blobID: String, volumePath: String?) throws -> Data {
        guard blobID.count > 1 else {
            throw BackendError.message("invalid blob ID: \(blobID)")
        }

        let storeID = String(blobID.prefix(1))
        guard storeID == "0" else {
            throw BackendError.message("unknown store ID: '\(storeID)'")
        }

        let rawID = String(blobID.dropFirst())
        let store = BlobStore(volumePath: volumePath)
        let fileID = fileID(rawID)
        let path = store.baseDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(fileID)
        let encrypted = try Data(contentsOf: path)
        return try decrypt(id: rawID, encrypted: encrypted)
    }

    private static func generateID() throws -> String {
        let alphabet = Array("0123456789ABCDEF")
        var bytes = [UInt8](repeating: 0, count: 7)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BackendError.message("failed to generate blob ID")
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func fileID(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func key(for id: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data("bunnylol:\(id)".utf8))
        return SymmetricKey(data: Data(digest))
    }

    private static func encrypt(id: String, plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key(for: id))
        guard let combined = sealed.combined else {
            throw BackendError.message("encryption failed")
        }
        return combined
    }

    private static func decrypt(id: String, encrypted: Data) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        return try AES.GCM.open(sealed, using: key(for: id))
    }
}
