import Foundation

struct ReleaseInfo {
    let version: String
    let assets: [ReleaseAsset]
}

struct ReleaseAsset {
    let name: String
    let downloadURL: URL
}

struct ReleaseAssetSelection {
    let version: String
    let archive: ReleaseAsset
    let checksum: ReleaseAsset
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
