import CryptoKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Relay

private actor StreamedUploadFixture {
    var id = ""
    var size: Int64 = 0
    var sha256 = ""
    var offset: Int64 = 0
    var largestChunk = 0
    var checksum = SHA256()
    var committed = false
    let failCommit: Bool
    init(failCommit: Bool = false) { self.failCommit = failCommit }

    func fetch(_ request: RemoteUploadRequest) throws -> RemoteUploadReceipt {
        switch request.operation {
        case "file_upload_begin": id = request.jobID; size = request.size!; sha256 = request.sha256!
        case "file_upload_chunk":
            guard request.offset == offset, let data = request.data else { throw RemoteFileTransferError.invalidResponse }
            checksum.update(data: data); offset += Int64(data.count); largestChunk = max(largestChunk, data.count)
        case "file_upload_commit":
            if failCommit { throw RemoteFileTransferError.failed("Proof commit failed") }
            guard offset == size, digest == sha256 else { throw RemoteFileTransferError.invalidResponse }
            committed = true
        default: throw RemoteFileTransferError.invalidResponse
        }
        return RemoteUploadReceipt(id: id, state: committed ? "committed" : "receiving", size: size, sha256: sha256,
            offset: offset, directory: "/uploads", path: committed ? "/uploads/proof.bin" : nil, prefixSHA256: digest)
    }
    private var digest: String { checksum.finalize().map { String(format: "%02x", $0) }.joined() }
}

private actor TransferProgressRecorder {
    var updates: [RelayTransferProgress] = []
    func record(_ progress: RelayTransferProgress) { updates.append(progress) }
}

@Test("A file above 64 MiB streams with acknowledged byte progress and verified completion")
func largeUploadProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-large-progress-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("proof.bin")
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let file = try FileHandle(forWritingTo: source)
    let size: Int64 = (80 << 20) + 123
    try file.truncate(atOffset: UInt64(size)); try file.close()
    let fixture = StreamedUploadFixture(), recorder = TransferProgressRecorder()
    let upload = try RemoteUpload(source: source, pane: "large-progress-proof", profile: .local, root: root.appendingPathComponent("private"))
    let entry = try await upload.upload(resume: false, progress: { await recorder.record($0) }, fetch: { try await fixture.fetch($0) })
    let updates = await recorder.updates
    #expect(entry.size == size)
    #expect(await fixture.largestChunk <= 4 << 20)
    #expect(updates.first?.phase == .preparing)
    #expect(updates.last?.phase == .complete)
    #expect(updates.last?.completedBytes == size)
    #expect(updates.last?.fraction == 1)
    let offsets = updates.filter { $0.phase == .uploading }.map(\.completedBytes)
    #expect(offsets.first == 0 && offsets.last == size)
    #expect(offsets == offsets.sorted())
    #expect(updates.contains { $0.phase == .verifying })
}

@Test("A failed commit never reports a completed upload")
func uploadCommitFailureProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-failed-progress-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("proof.bin")
    try Data([1, 2, 3]).write(to: source)
    let fixture = StreamedUploadFixture(failCommit: true), recorder = TransferProgressRecorder()
    let upload = try RemoteUpload(source: source, pane: "failed-progress-proof", profile: .local, root: root.appendingPathComponent("private"))
    await #expect(throws: (any Error).self) {
        _ = try await upload.upload(resume: false, progress: { await recorder.record($0) }, fetch: { try await fixture.fetch($0) })
    }
    #expect(await recorder.updates.allSatisfy { $0.phase != .complete })
}

@Test("Large image files use the authenticated streaming image reader")
func largeImageDescriptorPreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-large-image-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let source = root.appendingPathComponent("large.png")
    try (bytes as Data).write(to: source)
    let file = try FileHandle(forWritingTo: source)
    try file.truncate(atOffset: 80 << 20); try file.close()
    let snapshot = try await RelayAgentAttachmentSnapshot.captureAsync(source, directory: root.appendingPathComponent("cache"))
    #expect(snapshot.bytes == 80 << 20)
    #expect(try RelayAttachmentImageSource.read(snapshot) { CGImageSourceGetCount($0) } == 1)
    #expect(try await RelayAgentImagePreparation.shared.prepare(snapshot, directory: root.appendingPathComponent("cache")) == nil)
    try Data(repeating: 0, count: 10).write(to: snapshot.url, options: .atomic)
    #expect(throws: (any Error).self) { try RelayAttachmentImageSource.read(snapshot) { CGImageSourceGetCount($0) } }
}
