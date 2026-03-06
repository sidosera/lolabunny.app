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

    var precedenceScore: Int {
        (major * 100) + (minor * 10) + patch
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        lhs.precedenceScore < rhs.precedenceScore
    }
}

struct UpdateState {
    var lastCheckedAt: TimeInterval?
    var lastNotifiedBackendVersion: String?
}

struct UpdateCheckOutcome {
    let checkedAt: TimeInterval
    let backendLatestAvailable: String?
    let error: String?
}

enum BackendSetupState {
    case starting
    case waitingForDownloadPermission(requiredMajor: String)
    case downloading(phase: String, progress: Double)
    case ready(version: String)
    case blocked(message: String)
}
