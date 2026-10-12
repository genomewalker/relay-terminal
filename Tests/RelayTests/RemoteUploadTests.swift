import Foundation
import CryptoKit
import Testing
@testable import Relay

private actor UploadFixture {
    var bytes = Data()
    var id = ""
    var expectedSize: Int64 = 0
    var expectedSHA256 = ""
    var state = "receiving"
    var loseFirstChunkAck = true
    var offsets: [Int64] = []
    func fetch(_ request: RemoteUploadRequest) throws -> RemoteUploadReceipt {
        switch request.operation {
        case "file_upload_begin":
            id = request.jobID; expectedSize = request.size!; expectedSHA256 = request.sha256!
        case "file_upload_chunk":
            guard request.jobID == id, request.offset == Int64(bytes.count) else { throw RemoteFileTransferError.invalidResponse }
            offsets.append(request.offset!)
            bytes.append(request.data!)
            if loseFirstChunkAck { loseFirstChunkAck = false; throw CancellationError() }
        case "file_upload_commit":
            guard Int64(bytes.count) == expectedSize, digest(bytes) == expectedSHA256 else { throw RemoteFileTransferError.invalidResponse }
            state = "committed"
        case "file_upload_cancel": if state != "committed" { state = "cancelled" }
        case "file_upload_status": break
        default: throw RemoteFileTransferError.invalidResponse
        }
        return RemoteUploadReceipt(id: id, state: state, size: expectedSize, sha256: expectedSHA256, offset: Int64(bytes.count), directory: "/uploads", path: state == "committed" ? "/uploads/proof.bin" : nil, prefixSHA256: digest(bytes))
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private func uploadFixturePaths() throws -> (URL, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("relay-upload-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (base.appendingPathComponent("proof.bin"), base.appendingPathComponent("private"))
}

@Test("Native upload reopens its checkpoint and recovers a lost chunk acknowledgement")
func nativeUploadRecovery() async throws {
    let (source, root) = try uploadFixturePaths()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    try Data(repeating: 42, count: 5 << 20).write(to: source)
    let profile = ConnectionProfile.local
    let fixture = UploadFixture()
    var uploader: RemoteUpload? = try RemoteUpload(source: source, pane: "pane-proof", profile: profile, root: root)
    do {
        _ = try await uploader!.upload(resume: false, fetch: { try await fixture.fetch($0) })
        Issue.record("Expected lost acknowledgement")
    } catch is CancellationError { }
    uploader = nil
    let resumed = try RemoteUpload(source: source, pane: "pane-proof", profile: profile, root: root)
    await #expect(throws: (any Error).self) {
        _ = try await resumed.upload(resume: false, fetch: { try await fixture.fetch($0) })
    }
    let entry = try await resumed.upload(resume: true, fetch: { try await fixture.fetch($0) })
    #expect(entry.path == "/uploads/proof.bin")
    #expect(entry.size == 5 << 20)
    #expect(await fixture.offsets == [0, 4 << 20])
    // The receipt stays durable until an explicit forget, including completed files.
    let second = try await resumed.upload(resume: true, fetch: { try await fixture.fetch($0) })
    #expect(second.path == entry.path)
    #expect(await fixture.offsets == [0, 4 << 20])
    try await resumed.discard(fetch: { try await fixture.fetch($0) })
    #expect(await resumed.hasCheckpoint() == false)
}

@Test("Changed or missing source cannot resume but can discard a partial upload")
func nativeUploadChangedSource() async throws {
    let (source, root) = try uploadFixturePaths()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    try Data(repeating: 1, count: 1024).write(to: source)
    let fixture = UploadFixture()
    let uploader = try RemoteUpload(source: source, pane: "pane-proof", profile: .local, root: root)
    do { _ = try await uploader.upload(resume: false, fetch: { try await fixture.fetch($0) }) }
    catch is CancellationError { }
    try Data(repeating: 2, count: 1024).write(to: source)
    await #expect(throws: (any Error).self) {
        _ = try await uploader.upload(resume: true, fetch: { try await fixture.fetch($0) })
    }
    try FileManager.default.removeItem(at: source)
    try await uploader.discard(fetch: { try await fixture.fetch($0) })
    #expect(await uploader.hasCheckpoint() == false)
}

@Test("Native upload locks and host/backend bindings reject incompatible recovery")
func nativeUploadBindingAndLock() throws {
    let (source, root) = try uploadFixturePaths()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var profile = ConnectionProfile.local
    let first = try RemoteUpload.identity(source: source, pane: "pane-proof", profile: profile)
    profile.host = "changed-host"
    #expect(try RemoteUpload.identity(source: source, pane: "pane-proof", profile: profile) != first)
    #expect(try RemoteUpload.identity(source: source, pane: "different-pane", profile: .local) != first)
    let uploader = try RemoteUpload(source: source, pane: "pane-proof", profile: .local, root: root)
    #expect(throws: (any Error).self) { try RemoteUpload(source: source, pane: "pane-proof", profile: .local, root: root) }
    withExtendedLifetime(uploader) { }
}

@Test("Native upload rejects a symlink checkpoint root")
func nativeUploadUnsafeRoot() throws {
    let (source, root) = try uploadFixturePaths()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: source.deletingLastPathComponent())
    #expect(throws: (any Error).self) { try RemoteUpload(source: source, pane: "pane-proof", profile: .local, root: root) }
}
