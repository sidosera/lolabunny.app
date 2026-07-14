import Foundation

struct ReleaseInfo {
    let version: String
    let archiveURL: URL
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
    var lastNotifiedServerVersion: String?
}

struct UpdateCheckOutcome {
    let checkedAt: TimeInterval
    let serverLatestAvailable: String?
    let error: String?
}

public enum ServerSetupState {
    case GettingReady
    case WaitForDownloadPermission(requiredMajor: String)
    case DownloadInflight(phase: String, progress: Double)
    case Ready(version: String)
    case Failed(message: String)
}
