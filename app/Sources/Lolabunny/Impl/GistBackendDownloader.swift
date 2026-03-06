import Foundation

struct GistBackendDownloader: BackendDownloader {
    private let gistURL: URL
    private let manifestFileName: String?
    private let session: URLSession
    private let chunkSize: Int
    private let userAgent: String

    init?(
        gistID: String,
        manifestFileName: String? = nil,
        userAgent: String,
        session: URLSession = .shared,
        chunkSize: Int = 64 * 1024
    ) {
        let trimmedGistID = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGistID.isEmpty else {
            return nil
        }
        guard let gistURL = URL(string: "https://api.github.com/gists/\(trimmedGistID)") else {
            return nil
        }
        self.gistURL = gistURL
        if let manifestFileName {
            let trimmedManifest = manifestFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.manifestFileName = trimmedManifest.isEmpty ? nil : trimmedManifest
        } else {
            self.manifestFileName = nil
        }
        self.session = session
        self.chunkSize = chunkSize
        self.userAgent = userAgent
    }

    func fetchLatestRelease() async -> ReleaseInfo? {
        guard let manifestFileName else {
            log("gist release check failed: manifest file config missing")
            return nil
        }

        do {
            let gist = try await fetchGistPayload()
            guard let manifestFile = gist.file(named: manifestFileName),
                let manifestURL = manifestFile.rawURL
            else {
                log("gist release check failed: manifest file missing (\(manifestFileName))")
                return nil
            }

            let (manifestData, manifestResponse) = try await session.data(
                for: makeManifestRequest(url: manifestURL)
            )
            guard let manifestHTTP = manifestResponse as? HTTPURLResponse else {
                log("gist release check failed: missing manifest HTTP response")
                return nil
            }
            guard manifestHTTP.statusCode == 200 else {
                log("gist release check failed: manifest status=\(manifestHTTP.statusCode)")
                return nil
            }
            guard
                let manifest = try? JSONDecoder().decode(
                    GistManifestPayload.self,
                    from: manifestData
                )
            else {
                log("gist release check failed: invalid manifest payload")
                return nil
            }
            guard let selected = manifest.selectedRelease() else {
                log("gist release check failed: no releases in manifest")
                return nil
            }

            var assets: [ReleaseAsset] = []
            for assetName in selected.assets {
                let trimmedAssetName = assetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAssetName.isEmpty else {
                    continue
                }
                guard let file = gist.file(named: trimmedAssetName),
                    let rawURL = file.rawURL
                else {
                    log(
                        "gist release check failed: missing gist file for asset \(trimmedAssetName)"
                    )
                    return nil
                }
                assets.append(ReleaseAsset(name: trimmedAssetName, downloadURL: rawURL))
            }

            let version = selected.version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else {
                log("gist release check failed: selected release version is empty")
                return nil
            }

            return ReleaseInfo(version: version, assets: assets)
        } catch {
            log("gist release check failed: \(error.localizedDescription)")
            return nil
        }
    }

    func download(request: DownloadBackendRequest) async throws -> DownloadBackendResponse {
        if let sourceURL = request.sourceURL {
            return try await delegateDownload(
                sourceURL: sourceURL,
                request: DownloadBackendRequest(
                    version: request.version,
                    expectedSHA256Hex: request.expectedSHA256Hex,
                    sourceURL: sourceURL
                )
            )
        }

        let assetName = request.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetName.isEmpty else {
            throw BackendDownloadError(what: "missing gist asset name")
        }

        let gist = try await fetchGistPayload()
        guard let file = gist.file(named: assetName), let rawURL = file.rawURL else {
            throw BackendDownloadError(what: "missing gist file for asset \(assetName)")
        }

        return try await delegateDownload(
            sourceURL: rawURL,
            request: DownloadBackendRequest(
                version: request.version,
                expectedSHA256Hex: request.expectedSHA256Hex,
                sourceURL: rawURL
            )
        )
    }

    private func delegateDownload(
        sourceURL: URL,
        request: DownloadBackendRequest
    ) async throws -> DownloadBackendResponse {
        let httpDownloader = HttpBackendDownloader(
            baseURL: sourceURL.deletingLastPathComponent(),
            session: session,
            chunkSize: chunkSize,
            userAgent: userAgent
        )
        return try await httpDownloader.download(request: request)
    }

    private func fetchGistPayload() async throws -> GistPayload {
        let (gistData, gistResponse) = try await session.data(for: makeGistRequest())
        guard let gistHTTP = gistResponse as? HTTPURLResponse else {
            throw BackendDownloadError(what: "missing gist HTTP response")
        }
        guard gistHTTP.statusCode == 200 else {
            throw BackendDownloadError(what: "gist returned status \(gistHTTP.statusCode)")
        }
        guard let gist = try? JSONDecoder().decode(GistPayload.self, from: gistData) else {
            throw BackendDownloadError(what: "invalid gist payload")
        }
        return gist
    }

    private func makeGistRequest() -> URLRequest {
        var request = URLRequest(url: gistURL)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func makeManifestRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
}

private struct GistPayload: Decodable {
    let files: [String: GistFilePayload]

    func file(named targetName: String) -> GistFilePayload? {
        if let exact = files[targetName] {
            return exact
        }
        return files.values.first { $0.filename == targetName }
    }
}

private struct GistFilePayload: Decodable {
    let filename: String
    let rawURL: URL?

    private enum CodingKeys: String, CodingKey {
        case filename
        case rawURL = "raw_url"
    }
}

private struct GistManifestPayload: Decodable {
    let latest: String?
    let releases: [GistManifestReleasePayload]

    private enum CodingKeys: String, CodingKey {
        case latest
        case releases
        case version
        case assets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try container.decodeIfPresent(String.self, forKey: .latest)

        if let list = try container.decodeIfPresent(
            [GistManifestReleasePayload].self,
            forKey: .releases
        ), !list.isEmpty {
            releases = list
            return
        }

        if let version = try container.decodeIfPresent(String.self, forKey: .version),
            let assets = try container.decodeIfPresent([String].self, forKey: .assets)
        {
            releases = [GistManifestReleasePayload(version: version, assets: assets)]
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .releases,
            in: container,
            debugDescription: "Manifest must include 'releases' or ('version' and 'assets')."
        )
    }

    func selectedRelease() -> GistManifestReleasePayload? {
        let available = releases.filter {
            !$0.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !available.isEmpty else {
            return nil
        }

        if let latest = latest?.trimmingCharacters(in: .whitespacesAndNewlines),
            !latest.isEmpty,
            let matching = available.first(where: {
                $0.version.trimmingCharacters(in: .whitespacesAndNewlines) == latest
            })
        {
            return matching
        }
        return available.last ?? available.first
    }
}

private struct GistManifestReleasePayload: Decodable {
    let version: String
    let assets: [String]
}
