import Foundation

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct ReleaseAssetSelection {
    let version: String
    let archive: GitHubAsset
    let checksum: GitHubAsset
}

struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct UpdateState {
    var lastCheckedAt: TimeInterval?
    var lastNotifiedServerVersion: String?
}

struct UpdateCheckOutcome {
    let checkedAt: TimeInterval
    let serverLatestAvailable: String?
    let error: String?
}
