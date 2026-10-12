import Foundation
import Testing
@testable import Relay

/// Deterministic transport fixture: no GitHub access or third-party packages.
private final class PluginFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let tag = url.lastPathComponent
            let package = RelayPluginPackage(schemaVersion: 1, apiVersion: 1, id: "fixture.plugin", name: "Fixture", version: "1.0.0", repository: "fixture/plugin", permissions: [], contributions: [])
            let payload = try JSONEncoder().encode(package)
            let data: Data
            var status = 200
            if url.host == "github.com" {
                data = payload
            } else if tag == "not-found" {
                status = 404
                data = Data()
            } else {
                let asset: [String: Any] = [
                    "name": "relay-plugin.json", "size": tag == "bad-size" ? payload.count + 1 : payload.count,
                    "browser_download_url": tag == "bad-host" ? "https://attacker.example/package" : "https://github.com/fixture/plugin/releases/download/v1/relay-plugin.json",
                    "digest": tag == "bad-digest" ? "sha256:wrong" : NSNull()
                ]
                data = try JSONSerialization.data(withJSONObject: [
                    "tag_name": tag == "bad-tag" ? "different" : tag,
                    "draft": tag == "draft",
                    "assets": tag == "duplicate" ? [asset, asset] : [asset]
                ])
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@Test("Plugin GitHub review validates a complete download without installing it")
func pluginDownloadReview() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PluginFixtureProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let reviewed = try await RelayPluginReleaseLoader.review(repository: "fixture/plugin", tag: "v1", testSession: session)
    #expect(reviewed.package.id == "fixture.plugin")
    #expect(reviewed.digest.count == 64)
    let pasted = try await RelayPluginReleaseLoader.review(repository: " fixture/plugin\n", tag: " v1\r\n", testSession: session)
    #expect(pasted.releaseTag == "v1")
    for tag in ["not-found", "bad-tag", "draft", "duplicate", "bad-host", "bad-size", "bad-digest"] {
        await #expect(throws: (any Error).self) {
            try await RelayPluginReleaseLoader.review(repository: "fixture/plugin", tag: tag, testSession: session)
        }
    }
}

@Test("Plugin tag validation distinguishes empty, oversized and invisible input")
func pluginTagInput() throws {
    #expect(try RelayPluginReleaseLoader.normalizedTag("v0.1.0") == "v0.1.0")
    #expect(try RelayPluginReleaseLoader.normalizedTag("relay-test-nonexistent-release-20260918") == "relay-test-nonexistent-release-20260918")
    #expect(try RelayPluginReleaseLoader.normalizedTag(" \tv1\r\n") == "v1")
    // Foundation includes zero-width boundary whitespace in this character set.
    #expect(try RelayPluginReleaseLoader.normalizedTag("v1\u{200B}") == "v1")
    for input in ["", "\r\n", String(repeating: "x", count: 129), "v\u{200B}1", "v1\nsecond", "v1 second"] {
        #expect(throws: (any Error).self) { try RelayPluginReleaseLoader.normalizedTag(input) }
    }
}

@Test("Published HPC prerelease can be reviewed without installation",
      .enabled(if: ProcessInfo.processInfo.environment["RELAY_TEST_LIVE_PLUGIN"] == "1"))
func pluginLiveHPCReview() async throws {
    let candidate = try await RelayPluginReleaseLoader.review(
        repository: "genomewalker/relay-plugin-hpc-jobs", tag: "v0.1.0")
    #expect(candidate.releaseTag == "v0.1.0")
    #expect(candidate.package.id == "relay.hpc-jobs")
    #expect(candidate.package.supportsActivation)
}
