import Foundation

/// No credentials, repository checkout, archive extraction or installation hooks.
/// Redirects are constrained before a connection to the redirected host is made.
final class PluginDownloadPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

enum RelayPluginReleaseLoader {
    /// Native fields and pasted release URLs can carry surrounding line endings.
    /// Normalize only that boundary; never silently change the tag itself.
    static func normalizedTag(_ input: String) throws -> String {
        let tag = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw PluginError.invalid("Enter a release tag, for example v1.0.0") }
        guard tag.count <= 128 else { throw PluginError.invalid("Release tags must be at most 128 characters") }
        let controls = tag.unicodeScalars.filter { CharacterSet.controlCharacters.contains($0) }
        guard controls.isEmpty else {
            let codes = Set(controls.map { String(format: "U+%04X", $0.value) }).sorted().joined(separator: ", ")
            throw PluginError.invalid("Release tag contains invisible control characters (\(codes)); remove them and retry")
        }
        guard !tag.contains(where: \.isWhitespace) else { throw PluginError.invalid("Release tags cannot contain spaces") }
        return tag
    }

    struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: URL
            let digest: String?
        }
    }

    static func review(repository: String, tag: String, testSession: URLSession? = nil) async throws -> ReviewedPluginCandidate {
        let source = try GitHubPluginRepository(repository.trimmingCharacters(in: .whitespacesAndNewlines))
        let tag = try normalizedTag(tag)
        let url = URL(string: "https://api.github.com/repos/\(source.slug)/releases/tags/")!.appendingPathComponent(tag)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = testSession ?? URLSession(configuration: config, delegate: PluginDownloadPolicy(), delegateQueue: nil)
        defer { if testSession == nil { session.invalidateAndCancel() } }
        let metadata = try await download(url, maximum: 2 * 1024 * 1024, session: session)
        let release = try JSONDecoder().decode(Release.self, from: metadata)
        guard !release.draft, release.tag_name == tag else { throw PluginError.invalid("Release tag does not match") }
        let matching = release.assets.filter { $0.name == "relay-plugin.json" }
        guard matching.count == 1, let asset = matching.first,
              asset.size > 0, asset.size <= RelayPluginPackage.maximumBytes else {
            throw PluginError.invalid("Release must contain one relay-plugin.json asset, no larger than 256 KiB")
        }
        let bytes = try await download(asset.browser_download_url, maximum: RelayPluginPackage.maximumBytes, session: session)
        guard bytes.count == asset.size else { throw PluginError.invalid("Release asset size changed") }
        let candidate = try ReviewedPluginCandidate(bytes: bytes, repository: source.slug, releaseTag: tag)
        if let digest = asset.digest {
            guard digest == "sha256:" + candidate.digest else { throw PluginError.invalid("GitHub asset digest does not match downloaded bytes") }
        }
        return candidate
    }

    private static func download(_ url: URL, maximum: Int, session: URLSession) async throws -> Data {
        guard PluginDownloadPolicy.allows(url) else { throw PluginError.invalid("Unsupported download host") }
        var request = URLRequest(url: url)
        request.setValue("Relay-Plugin-Installer", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PluginError.invalid("GitHub download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)); check the repository, tag or rate limit")
        }
        guard response.expectedContentLength <= Int64(maximum) else { throw PluginError.invalid("Download exceeds size limit") }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximum else { throw PluginError.invalid("Download exceeds size limit") }
            data.append(byte)
        }
        return data
    }
}
