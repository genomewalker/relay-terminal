import Foundation
import CryptoKit
import Testing
@testable import Relay

@Test @MainActor func transferPresentationChangesGenerationOnlyForNewTarget() throws {
    let presentation = PluginTransferPresentation()
    let scope = try PluginScope(paneID: UUID(), profile: .local, root: "/test")
    let a = PluginTransferStamp(pluginID: "test", digest: "v1", scope: scope, path: "a.csv")
    presentation.configure(a)
    let first = presentation.generation
    presentation.configure(a)
    #expect(presentation.generation == first)
    presentation.configure(PluginTransferStamp(pluginID: "test", digest: "v1", scope: scope, path: "b.csv"))
    #expect(presentation.generation == first + 1)
    #expect(presentation.completed == 0)
    #expect(!presentation.ready)
}

private actor TransferFixture {
    let bytes: Data
    var failOnce = true
    var offsets: [Int64] = []
    init(bytes: Data) { self.bytes = bytes }
    func fetch(_ request: PluginTransferRequest) throws -> PluginOperationResult {
        let version = String(repeating: "a", count: 64)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var result = PluginOperationResult(root: "/tmp", text: "large", entries: [], truncated: false)
        result.transfer = PluginTransferInfo(version: version, size: Int64(bytes.count), offset: request.offset, sha256: request.mode == "verify" ? digest : nil)
        if request.mode == "chunk" {
            if request.offset > 0 && failOnce { failOnce = false; throw CancellationError() }
            offsets.append(request.offset)
            result.verifiedBytes = bytes.subdata(in: Int(request.offset)..<min(bytes.count, Int(request.offset) + (4 << 20)))
        }
        return result
    }
}

@Test("Chunked download resumes verified bytes and saves only a complete file")
func pluginTransferResume() async throws {
    let fixture = TransferFixture(bytes: Data(repeating: 42, count: 5 << 20))
    let download = try PluginTransferDownload()
    do {
        _ = try await download.download(fetch: { try await fixture.fetch($0) }, progress: { _, _ in })
        Issue.record("Expected interruption")
    } catch is CancellationError { }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: (any Error).self) { try await download.save(to: destination) }
    _ = try await download.download(fetch: { try await fixture.fetch($0) }, progress: { _, _ in })
    try await download.save(to: destination)
    #expect(try Data(contentsOf: destination) == Data(repeating: 42, count: 5 << 20))
    #expect(await fixture.offsets == [0, 4 << 20])
}

@Test("Transfer responses must match the requested identity, offset and chunk length")
func pluginTransferResponseValidation() throws {
    let version = String(repeating: "a", count: 64)
    let request = PluginTransferRequest(mode: "chunk", version: version, offset: 0)
    var response = PluginOperationResult(root: "/tmp", text: "file", entries: [], truncated: false)
    response.transfer = PluginTransferInfo(version: version, size: 10, offset: 0, sha256: nil)
    response.verifiedBytes = Data(repeating: 0, count: 9)
    #expect(throws: (any Error).self) { try request.validate(response, path: "file") }
    response.verifiedBytes = Data(repeating: 0, count: 10)
    try request.validate(response, path: "file")
    #expect(throws: (any Error).self) { try request.validate(response, path: "other") }
}

@Test("Persisted transfer rebuilds its verified prefix after the downloader is released")
func pluginTransferPersistentRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = String(repeating: "b", count: 64)
    let fixture = TransferFixture(bytes: Data(repeating: 17, count: 5 << 20))
    do {
        let first = try PluginTransferDownload(persistenceKey: key, root: root)
        do {
            _ = try await first.download(fetch: { try await fixture.fetch($0) }, progress: { _, _ in })
            Issue.record("Expected interruption")
        } catch is CancellationError { }
    }
    let spool = root.appendingPathComponent(key).appendingPathComponent("download")
    let tail = try FileHandle(forWritingTo: spool)
    try tail.seekToEnd(); try tail.write(contentsOf: Data([1, 2, 3])); try tail.close()
    let recovered = try PluginTransferDownload(persistenceKey: key, root: root)
    #expect(try spool.resourceValues(forKeys: [.fileSizeKey]).fileSize == 4 << 20)
    _ = try await recovered.download(fetch: { try await fixture.fetch($0) }, progress: { _, _ in })
    let destination = root.appendingPathComponent("result")
    try await recovered.save(to: destination)
    #expect(try Data(contentsOf: destination) == Data(repeating: 17, count: 5 << 20))
    #expect(await fixture.offsets == [0, 4 << 20])
    try await recovered.discard()
    #expect(!FileManager.default.fileExists(atPath: spool.path))
}

@Test("Persisted transfer rejects concurrent owners, corrupted prefixes and symlink roots")
func pluginTransferPersistentProtection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = String(repeating: "c", count: 64)
    let fixture = TransferFixture(bytes: Data(repeating: 17, count: 5 << 20))
    do {
        let first = try PluginTransferDownload(persistenceKey: key, root: root)
        #expect(throws: (any Error).self) { try PluginTransferDownload(persistenceKey: key, root: root) }
        do { _ = try await first.download(fetch: { try await fixture.fetch($0) }, progress: { _, _ in }) }
        catch is CancellationError { }
    }
    let spool = root.appendingPathComponent(key).appendingPathComponent("download")
    let corrupt = try FileHandle(forWritingTo: spool)
    try corrupt.write(contentsOf: Data([0])); try corrupt.close()
    #expect(throws: (any Error).self) { try PluginTransferDownload(persistenceKey: key, root: root) }
    let reset = try PluginTransferDownload(persistenceKey: key, root: root, discardExisting: true)
    try await reset.discard()
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    #expect(throws: (any Error).self) { try PluginTransferDownload(persistenceKey: key, root: link) }
}

@Test @MainActor func pluginTransferStampBindsPersistentRecovery() throws {
    let pane = UUID()
    let scope = try PluginScope(paneID: pane, profile: .local, root: "/one")
    let a = PluginTransferStamp(pluginID: "test", digest: "v1", scope: scope, path: "file")
    #expect(a.persistenceKey == a.persistenceKey)
    #expect(a.persistenceKey != PluginTransferStamp(pluginID: "test", digest: "v2", scope: scope, path: "file").persistenceKey)
    #expect(a.persistenceKey != PluginTransferStamp(pluginID: "test", digest: "v1", scope: scope, path: "other").persistenceKey)
    let other = try PluginScope(paneID: UUID(), profile: .local, root: "/one")
    #expect(a.persistenceKey != PluginTransferStamp(pluginID: "test", digest: "v1", scope: other, path: "file").persistenceKey)
}
