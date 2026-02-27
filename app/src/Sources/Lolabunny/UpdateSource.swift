import Foundation

@MainActor
protocol UpdateSource {
    func fetchLatestRelease() async -> ReleaseInfo?
}

struct DisabledUpdateSource: UpdateSource {
    func fetchLatestRelease() async -> ReleaseInfo? {
        nil
    }
}

final class GitHubUpdateSource: UpdateSource {
    private let latestReleaseURL: URL
    private let userAgent: String
    private let session: URLSession

    init?(
        org: String,
        repository: String,
        userAgent: String,
        session: URLSession = .shared
    ) {
        let trimmedOrg = org.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrg.isEmpty, !trimmedRepository.isEmpty else {
            return nil
        }

        guard let latestReleaseURL = URL(
            string: "https://api.github.com/repos/\(trimmedOrg)/\(trimmedRepository)/releases/latest"
        ) else {
            return nil
        }
        self.latestReleaseURL = latestReleaseURL
        self.userAgent = userAgent
        self.session = session
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        var req = URLRequest(url: latestReleaseURL)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                log("latest release check failed: missing HTTP response")
                return nil
            }
            guard http.statusCode == 200 else {
                log("latest release check failed: status=\(http.statusCode)")
                return nil
            }
            guard let release = try? JSONDecoder().decode(GitHubReleasePayload.self, from: data) else {
                log("latest release check failed: invalid response payload")
                return nil
            }
            let assets = release.assets.map {
                ReleaseAsset(name: $0.name, downloadURL: $0.browserDownloadURL)
            }
            return ReleaseInfo(version: release.tagName, assets: assets)
        } catch {
            log("latest release check failed: \(error.localizedDescription)")
            return nil
        }
    }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let assets: [GitHubAssetPayload]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAssetPayload: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
