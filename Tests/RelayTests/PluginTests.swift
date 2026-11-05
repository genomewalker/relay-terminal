import Foundation
import Testing
@testable import Relay

@Test("Local manifest review keeps validation and labels development provenance")
func localPluginReview() throws {
    let original = try pluginCandidate()
    let reviewed = try ReviewedPluginCandidate.localManifest(original.bytes)
    #expect(reviewed.digest == original.digest)
    #expect(reviewed.releaseTag == "local-review")
    #expect(throws: (any Error).self) { try ReviewedPluginCandidate.localManifest(Data(repeating: 32, count: 262145)) }
    #expect(throws: (any Error).self) { try ReviewedPluginCandidate.localManifest(Data("{}".utf8)) }
}

private func pluginCandidate(version: String = "1.0.0", permissions: [RelayPluginPackage.Permission] = [], text: String = "Test") throws -> ReviewedPluginCandidate {
    let package = RelayPluginPackage(schemaVersion: 1, apiVersion: 1, id: "example.jobs", name: "Jobs", version: version,
        repository: "example/jobs", permissions: permissions,
        contributions: [.init(id: "info", kind: .information, title: "Jobs", text: text, url: nil)])
    return try ReviewedPluginCandidate(bytes: JSONEncoder().encode(package), repository: "example/jobs", releaseTag: "v" + version)
}

@Test("Plugin sources reject credential, path and query confusion")
func pluginSourceValidation() throws {
    #expect(try GitHubPluginRepository("https://github.com/Example/Jobs/").slug == "example/jobs")
    for bad in ["https://github.com.evil/x/y", "https://user@github.com/x/y", "x/../y", "x/y?token=secret", "x/%2f", "x/..", "/x/y"] {
        #expect(throws: (any Error).self) { try GitHubPluginRepository(bad) }
    }
}

@Test("Plugin candidates accept ordinary release tags and reject control characters")
func pluginCandidateTags() throws {
    let bytes = try pluginCandidate().bytes
    for tag in ["v0.1.0", "release/1.0", "版本-1"] {
        let candidate = try ReviewedPluginCandidate(bytes: bytes, repository: "example/jobs", releaseTag: tag)
        #expect(candidate.releaseTag == tag)
    }
    for tag in ["", "v1\0", "v1\n", String(repeating: "x", count: 129)] {
        #expect(throws: (any Error).self) {
            try ReviewedPluginCandidate(bytes: bytes, repository: "example/jobs", releaseTag: tag)
        }
    }
}

@Test("Plugin download redirects reject non-GitHub destinations and credentials")
func pluginDownloadDestinations() throws {
    for raw in ["https://api.github.com/repos/example/jobs", "https://release-assets.githubusercontent.com/file"] {
        #expect(PluginDownloadPolicy.allows(try #require(URL(string: raw))))
    }
    for raw in ["http://github.com/file", "https://github.com.evil/file", "https://user:secret@github.com/file", "https://127.0.0.1/file", "https://github.com:444/file"] {
        #expect(!PluginDownloadPolicy.allows(try #require(URL(string: raw))))
    }
}

@Test("Plugin manifests are bounded and cannot declare executable entrypoints")
func pluginManifestValidation() throws {
    let good = try pluginCandidate()
    #expect(good.digest.count == 64)
    var object = try #require(JSONSerialization.jsonObject(with: good.bytes) as? [String: Any])
    object["entrypoint"] = "install.sh"
    let unsupported = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try RelayPluginPackage.decode(unsupported, repository: "example/jobs") }
    object.removeValue(forKey: "entrypoint")
    object["permissions"] = [["kind": "projectRead", "reason": "Test", "path": "/"]]
    let scopedByPublisher = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try RelayPluginPackage.decode(scopedByPublisher, repository: "example/jobs") }
    #expect(throws: (any Error).self) { try RelayPluginPackage.decode(Data(repeating: 32, count: 262145), repository: "example/jobs") }
    #expect(throws: (any Error).self) { try RelayPluginPackage.decode(good.bytes, repository: "attacker/jobs") }
}

@Test("Plugin install, update and rollback never silently activate code or permissions")
func pluginLifecycle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelayPluginStore(directory: directory)
    let first = try pluginCandidate()
    await #expect(throws: (any Error).self) { try await store.install(first, approvedDigest: "wrong") }
    try await store.install(first, approvedDigest: first.digest)
    #expect(try await store.activePackages().isEmpty)
    try await store.setEnabled(first.package.id, true)
    #expect(try await store.activePackages().count == 1)
    // Same bytes are idempotent and do not disturb the active revision.
    try await store.install(first, approvedDigest: first.digest)
    #expect(try await store.activePackages().count == 1)
    let changed = try pluginCandidate(text: "Republished")
    await #expect(throws: (any Error).self) { try await store.install(changed, approvedDigest: changed.digest) }
    let second = try pluginCandidate(version: "2.0.0", permissions: [.init(kind: .projectRead, reason: "Read jobs")])
    try await store.install(second, approvedDigest: second.digest)
    #expect(try await store.activePackages().isEmpty)
    await #expect(throws: (any Error).self) { try await store.setEnabled(second.package.id, true) }
    try await store.rollback(second.package.id)
    try await store.setEnabled(first.package.id, true)
    let reopened = RelayPluginStore(directory: directory)
    #expect(try await reopened.activePackages().first?.version == "1.0.0")
    try await reopened.setEnabled(first.package.id, false)
    #expect(try await store.activePackages().isEmpty)
    try await store.setEnabled(first.package.id, true)
    let safe = RelayPluginStore(directory: directory, safeMode: true)
    #expect(try await safe.activePackages().isEmpty)
    await #expect(throws: (any Error).self) { try await safe.setEnabled(first.package.id, true) }
    try await store.uninstall(first.package.id)
    #expect(try await store.installations().isEmpty)
}

@Test("Corrupt plugin state fails closed without being overwritten")
func pluginCorruptState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("installations.json")
    let invalid = Data("not valid JSON".utf8)
    try invalid.write(to: file)
    let store = RelayPluginStore(directory: directory)
    let candidate = try pluginCandidate()
    await #expect(throws: (any Error).self) { try await store.install(candidate, approvedDigest: candidate.digest) }
    #expect(try Data(contentsOf: file) == invalid)
}

@Test("Plugin manager refreshes cached display packages after external changes", .timeLimit(.minutes(5)))
@MainActor
func pluginManagerDisplayCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelayPluginStore(directory: directory)
    let candidate = try pluginCandidate()
    try await store.install(candidate, approvedDigest: candidate.digest)
    let manager = RelayPluginManager(directory: directory)

    // Wait for the operation itself; the test's time limit bounds a hang. A
    // wall-clock bound here also counts time spent queued behind other
    // MainActor tests in the suite.
    func settle() async throws {
        while manager.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!manager.busy)
        #expect(manager.error == nil)
    }

    manager.refresh()
    try await settle()
    #expect(manager.reviewedInstallations[candidate.package.id]?.digest == candidate.digest)
    #expect(manager.installations[candidate.package.id]?.enabled == false)

    // A cache is for display only. External removal must still be discovered.
    try await store.uninstall(candidate.package.id)
    manager.refresh()
    try await settle()
    #expect(manager.installations.isEmpty)
    #expect(manager.reviewedInstallations.isEmpty)
}
