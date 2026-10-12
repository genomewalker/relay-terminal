import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Relay

private func attachmentRasterFixture(_ type: UTType, orientation: Int = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: 2, height: 3,
        bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

@Test func rasterPreparationPreservesOriginalAndAppliesOrientation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("original.tiff")
    let original = try attachmentRasterFixture(.tiff, orientation: 6)
    try original.write(to: source)
    let directory = root.appendingPathComponent("cache")
    let captured = try RelayAgentAttachmentSnapshot.capture(source, directory: directory)
    let prepared = try #require(try await RelayAgentImagePreparation.shared.prepare(captured, directory: directory))
    #expect(prepared.url != captured.url)
    #expect(prepared.url.pathExtension == "png")
    #expect(try captured.verifiedData() == original)
    #expect(try Data(contentsOf: source) == original)
    let bytes = try prepared.verifiedData()
    let decoded = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 3 && image.height == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix("conversion-") })
    let png = root.appendingPathComponent("original.png")
    let pngBytes = try attachmentRasterFixture(.png)
    try pngBytes.write(to: png)
    let pngCapture = try RelayAgentAttachmentSnapshot.capture(png, directory: directory)
    #expect(try await RelayAgentImagePreparation.shared.prepare(pngCapture, directory: directory) == nil)
    #expect(try pngCapture.verifiedData() == pngBytes)
}

@Test @MainActor func imageQueuePersistsBothCapturesAndRejectsTamperedConversion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("photo.tiff")
    let original = try attachmentRasterFixture(.tiff)
    try original.write(to: source)
    let pane = PaneModel(profile: .local)
    let binding = RelayAgentConversationBinding(hostID: pane.profile.id.uuidString, paneID: pane.id,
        provider: "codex", processID: 200, processStart: "kernel:201", sessionID: "unit-image")
    let queue = RelayAgentAttachmentQueue()
    queue.stage([source])
    let id = try #require(queue.attachments.first?.id)
    queue.prepare(id, pane: pane, binding: binding, bindingIsCurrent: { true })
    await queue.waitForPreparation(id)
    let item = try #require(queue.attachments.first)
    let captured = try #require(item.snapshot)
    let prepared = try #require(item.nativeImageSnapshot)
    defer {
        try? FileManager.default.removeItem(at: captured.url)
        try? FileManager.default.removeItem(at: prepared.url)
    }
    #expect(item.ready(for: binding))
    #expect(item.uploadedPath == prepared.url.path)
    #expect(try captured.verifiedData() == original)
    let saved = try JSONDecoder().decode(RelayAgentDraftAttachment.self, from: JSONEncoder().encode(item))
    #expect(saved == item)
    let restored = RelayAgentAttachmentQueue()
    restored.restore([saved])
    #expect(await restored.validateForSend(binding: binding))
    try Data("changed prepared image".utf8).write(to: prepared.url, options: .atomic)
    #expect(!(await restored.validateForSend(binding: binding)))
    #expect(restored.attachments.first?.uploadedPath == nil)
    #expect(throws: (any Error).self) { try prepared.verifiedData() }
    #expect(try captured.verifiedData() == original)
}

@Test @MainActor func pastedImageStagingCopiesAreDiscardedOnlyAfterCaptureOrRemoval() async throws {
    let bytes = try attachmentRasterFixture(.png)
    let pane = PaneModel(profile: .local)
    let binding = RelayAgentConversationBinding(hostID: pane.profile.id.uuidString, paneID: pane.id,
        provider: "claude", processID: 200, processStart: "kernel:201", sessionID: "unit-pasted-image")
    let queue = RelayAgentAttachmentQueue()
    queue.stageImage(bytes)
    let staged = try #require(queue.attachments.first)
    #expect(FileManager.default.fileExists(atPath: staged.sourceURL.path))
    queue.prepare(staged.id, pane: pane, binding: binding, bindingIsCurrent: { true })
    await queue.waitForPreparation(staged.id)
    let ready = try #require(queue.attachments.first)
    let snapshot = try #require(ready.snapshot)
    defer { try? FileManager.default.removeItem(at: snapshot.url) }
    #expect(!FileManager.default.fileExists(atPath: staged.sourceURL.path))
    #expect(try snapshot.verifiedData() == bytes)
    #expect(await queue.validateForSend(binding: binding))
    queue.remove(staged.id)
    #expect(try snapshot.verifiedData() == bytes)
    let other = RelayAgentAttachmentQueue()
    other.stageImage(bytes)
    let pending = try #require(other.attachments.first)
    other.remove(pending.id)
    #expect(!FileManager.default.fileExists(atPath: pending.sourceURL.path))
}

@Test func nativeImagesAreAcknowledgedOnlyInTheCurrentComposer() {
    let rule = String(repeating: "─", count: 30)
    #expect(RelayNativeImageComposer.acknowledges(1, provider: "claude",
        rows: ["old [Image #2]", rule, "❯ [Image #1]", rule, "shortcuts"]))
    #expect(RelayNativeImageComposer.acknowledges(2, provider: "codex",
        rows: ["› [Image #1] [Image #", "2]", rule, "footer"]))
    #expect(RelayNativeImageComposer.acknowledges(1, provider: "codex",
        rows: ["› [Image #1]", "", "GPT-6.1-Sol low · directory · 2 warnings"]))
    #expect(!RelayNativeImageComposer.acknowledges(1, provider: "claude",
        rows: ["❯ [Image #1]", rule, "❯", rule]))
    #expect(!RelayNativeImageComposer.acknowledges(1, provider: "claude",
        rows: ["❯ [Image #1] foreign input", rule]))
    #expect(!RelayNativeImageComposer.acknowledges(2, provider: "claude",
        rows: ["❯ [Image #1] [Image #1]", rule]))
    #expect(!RelayNativeImageComposer.acknowledges(1, provider: "shell",
        rows: ["❯ [Image #1]", rule]))
    #expect(RelayNativeImageComposer.acknowledges(0, provider: "claude",
        rows: ["❯ Gray prediction", rule]))
    #expect(!RelayNativeImageComposer.acknowledges(0, provider: "claude",
        rows: ["❯ [Image #1]", rule]))
    #expect(RelayNativeImageComposer.quotedPath("/tmp/space 漢字.png") == "\"/tmp/space 漢字.png\"")
    for path in ["relative.png", "/tmp/image\n.png", "/tmp/image\u{001b}.png", "/tmp/quote\".png"] {
        #expect(RelayNativeImageComposer.quotedPath(path) == nil)
    }
}

@Test func attachmentOnlyDraftsRoundTripWithoutCrossingBindings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelayAgentDraftStore(directory: directory)
    let pane = UUID()
    let host = UUID().uuidString
    let binding = RelayAgentConversationBinding(hostID: host, paneID: pane, provider: "claude",
        processID: 120, processStart: "kernel:123", sessionID: "owned-session")
    let source = directory.appendingPathComponent("source.png")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: source)
    var item = RelayAgentDraftAttachment(sourceURL: URL(fileURLWithPath: "/tmp/image.png"), kind: .image)
    item.snapshot = try RelayAgentAttachmentSnapshot.capture(source, directory: directory.appendingPathComponent("captured"))
    item.uploadedPath = "/remote/image.png"; item.uploadedBinding = binding
    store.saveNow("", hostID: host, paneID: pane, attachments: [item])
    #expect(store.loadDraft(hostID: host, paneID: pane) == RelayAgentStoredDraft(text: "", attachments: [item]))
    #expect(store.loadDraft(hostID: host, paneID: UUID()) == nil)
    #expect(item.ready(for: binding))
    var changed = item
    changed.uploadedBinding = .init(hostID: host, paneID: pane, provider: "claude", processID: 120,
        processStart: "kernel:456", sessionID: "owned-session")
    #expect(!changed.ready(for: binding))
    store.saveNow("rejected", hostID: host, paneID: pane, attachments: [item, item])
    #expect(store.loadDraft(hostID: host, paneID: pane)?.text == "")
    let tooMany = (0..<33).map {
        RelayAgentDraftAttachment(sourceURL: URL(fileURLWithPath: "/tmp/file\($0)"), kind: .file)
    }
    store.saveNow("rejected", hostID: host, paneID: pane, attachments: tooMany)
    #expect(store.loadDraft(hostID: host, paneID: pane)?.attachments == [item])
    var foreign = item
    foreign.uploadedBinding = .init(hostID: "foreign", paneID: pane, provider: "claude", processID: 120,
        processStart: "kernel:123", sessionID: "owned-session")
    store.saveNow("rejected", hostID: host, paneID: pane, attachments: [foreign])
    #expect(store.loadDraft(hostID: host, paneID: pane)?.attachments == [item])
    store.saveNow("", hostID: host, paneID: pane)
    #expect(store.loadDraft(hostID: host, paneID: pane) == nil)
}

@Test func fileSnapshotsKeepExactBytesAndUseSafeIndependentPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("quote\"slash\\ 漢字.png")
    let bytes = Data((0...255).map(UInt8.init))
    try bytes.write(to: source)
    let record = try RelayAgentAttachmentSnapshot.capture(source, directory: root.appendingPathComponent("cache"))
    #expect(record.verify())
    #expect(try Data(contentsOf: record.url) == bytes)
    #expect(record.bytes == 256)
    #expect(record.url.pathExtension == "png")
    #expect(RelayNativeImageComposer.quotedPath(record.url.path) != nil)
    #expect(record.url != source)
    try Data("edited original".utf8).write(to: source, options: .atomic)
    #expect(record.verify())
    #expect(try Data(contentsOf: record.url) == bytes)
    let permissions = try #require(try FileManager.default.attributesOfItem(atPath: record.url.path)[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o400)
    // A replaced cache entry is rejected, even when its length is unchanged.
    try Data(repeating: 42, count: 256).write(to: record.url, options: .atomic)
    #expect(!record.verify())
}

@Test func snapshotCaptureRejectsSymlinksWithoutTouchingTheirTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try Data("owned original".utf8).write(to: source)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: (any Error).self) {
        try RelayAgentAttachmentSnapshot.capture(link, directory: root.appendingPathComponent("cache"))
    }
    #expect(try Data(contentsOf: source) == Data("owned original".utf8))
    let directoryLink = root.appendingPathComponent("cache-link")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
    #expect(throws: (any Error).self) {
        try RelayAgentAttachmentSnapshot.capture(source, directory: directoryLink)
    }
    #expect(try Data(contentsOf: source) == Data("owned original".utf8))
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
    #expect(throws: (any Error).self) {
        try RelayAgentAttachmentSnapshot.capture(fifo, directory: root.appendingPathComponent("cache"))
    }
}

@Test @MainActor func attachmentQueueUsesCapturedBytesAndRejectsLostBindings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("quoted\"name.txt")
    let original = Data("original  spaces 🧬\nsecond line".utf8)
    try original.write(to: source)
    let pane = PaneModel(profile: .local)
    let binding = RelayAgentConversationBinding(hostID: pane.profile.id.uuidString, paneID: pane.id,
        provider: "claude", processID: 200, processStart: "kernel:201", sessionID: "unit-fixture")
    let queue = RelayAgentAttachmentQueue()
    queue.stage([source])
    let id = try #require(queue.attachments.first?.id)
    queue.prepare(id, pane: pane, binding: binding, bindingIsCurrent: { true })
    await queue.waitForPreparation(id)
    let ready = try #require(queue.attachments.first)
    let snapshot = try #require(ready.snapshot)
    defer { try? FileManager.default.removeItem(at: snapshot.url) }
    #expect(ready.ready(for: binding))
    #expect(ready.name == source.lastPathComponent)
    #expect(ready.uploadedPath == snapshot.url.path)
    #expect(ready.uploadedPath != source.path)
    try Data("changed source".utf8).write(to: source, options: .atomic)
    #expect(await queue.validateForSend(binding: binding))
    #expect(try Data(contentsOf: snapshot.url) == original)
    #expect(pane.directory == nil)
    // The captured file is rejected when replaced; source edits are never
    // silently recaptured as though they were the staged attachment.
    try Data("changed cache".utf8).write(to: snapshot.url, options: .atomic)
    #expect(!(await queue.validateForSend(binding: binding)))
    #expect(queue.attachments.first?.uploadedPath == nil)
    let other = RelayAgentAttachmentQueue()
    other.stage([source])
    let otherID = try #require(other.attachments.first?.id)
    other.prepare(otherID, pane: pane, binding: binding, bindingIsCurrent: { false })
    await other.waitForPreparation(otherID)
    #expect(other.attachments.first?.uploadedPath == nil)
    #expect(other.attachments.first?.snapshot == nil)
    #expect(other.failures[otherID] != nil)
}
