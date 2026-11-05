import XCTest
@testable import Relay

final class RelayFilePreviewTests: XCTestCase {
    func testClassifierRecognisesImagesPDFsAndLogs() {
        for path in ["/a/b.png", "/a/B.JPG", "x.jpeg", "x.gif", "x.tiff", "x.tif", "x.bmp", "x.webp", "x.heic", "x.svg"] {
            XCTAssertEqual(RelayFilePreviewKind.from(path: path), .image, path)
        }
        XCTAssertEqual(RelayFilePreviewKind.from(path: "/reports/Plot.PDF"), .pdf)
        for path in ["run.log", "a.txt", "job.out", "job.err", "t.tsv", "t.csv", "README.md", "c.json", "c.yaml", "c.yml", "j.stdout", "j.stderr"] {
            XCTAssertEqual(RelayFilePreviewKind.from(path: path), .log, path)
        }
        for path in ["/bin/tool", "archive.tar.gz", "main.swift", ".log", "/dir/"] {
            XCTAssertNil(RelayFilePreviewKind.from(path: path), path)
        }
        XCTAssertEqual(RelayFilePreviewKind.image.symbol, "photo")
        XCTAssertEqual(RelayFilePreviewKind.pdf.symbol, "doc.richtext")
        XCTAssertEqual(RelayFilePreviewKind.log.symbol, "doc.plaintext")
    }

    func testSmallLogIsReadWhole() throws {
        let url = try temporaryFile(Data("first\nsecond\n".utf8))
        let tail = try RelayLogTail.readLocal(path: url.path)
        XCTAssertEqual(tail.text, "first\nsecond\n")
        XCTAssertEqual(tail.totalBytes, 13)
        XCTAssertFalse(tail.partial)
        XCTAssertNil(tail.label)
    }

    func testLargeLogReadsOnlyLabelledTail() throws {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: (1 << 20) + 500)
        bytes.append(contentsOf: Array("END\n".utf8))
        let url = try temporaryFile(bytes)
        let tail = try RelayLogTail.readLocal(path: url.path)
        XCTAssertTrue(tail.partial)
        XCTAssertEqual(tail.shownBytes, 1 << 20)
        XCTAssertEqual(tail.totalBytes, bytes.count)
        XCTAssertTrue(tail.text.hasSuffix("END\n"))
        XCTAssertEqual(tail.label, "Showing last 1048576 of \(bytes.count) bytes")
    }

    func testTailDropsSplitLeadingCharacterAndRefusesSymlinks() throws {
        let tail = RelayLogTail(bytes: Data([0xA9, 0x41]), totalBytes: 10)
        XCTAssertEqual(tail.text, "A")
        let url = try temporaryFile(Data("x".utf8))
        let link = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try RelayLogTail.readLocal(path: link.path))
    }

    func testActualSizeZoomMapsOneImagePixelToOneBackingPixel() {
        XCTAssertEqual(PaneArtifact.actualSizeZoom(pixelSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 400, height: 400), displayScale: 2), 2.5, accuracy: 0.0001)
        XCTAssertEqual(PaneArtifact.actualSizeZoom(pixelSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 400, height: 400), displayScale: 1), 5, accuracy: 0.0001)
        // A small image is upscaled to fit, so actual size is below the fit zoom.
        XCTAssertEqual(PaneArtifact.actualSizeZoom(pixelSize: CGSize(width: 100, height: 100),
            viewport: CGSize(width: 400, height: 200), displayScale: 2), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PaneArtifact.actualSizeZoom(pixelSize: .zero, viewport: CGSize(width: 1, height: 1), displayScale: 2), 1)
    }

    func testPaneArtifactKinds() {
        XCTAssertEqual(PaneArtifact(remotePath: "/r/p.pdf", data: Data("%PDF-1.7".utf8)).kind, .pdf)
        let image = PaneArtifact(remotePath: "/r/p.png", data: Data([0x89, 0x50]))
        XCTAssertEqual(image.kind, .image)
        XCTAssertFalse(image.userRequested)
        let log = PaneArtifact(remotePath: "/r/run.log", log: RelayLogTail(bytes: Data("tail".utf8), totalBytes: 9))
        XCTAssertEqual(log.kind, .log)
        XCTAssertEqual(log.text, "tail")
        XCTAssertEqual(log.totalBytes, 9)
        XCTAssertTrue(log.partial)
        XCTAssertTrue(log.userRequested)
        let failed = PaneArtifact(remotePath: "/r/missing.log", kind: .log, failure: "No such file")
        XCTAssertEqual(failed.failure, "No such file")
        XCTAssertNil(failed.text)
    }

    func testLocalLoaderShowsErrorForTheSameMissingPath() async {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".log"
        let artifact = await RelayFilePreviewLoader.load(path: path, profile: .local)
        XCTAssertEqual(artifact.remotePath, path)
        XCTAssertEqual(artifact.kind, .log)
        XCTAssertNotNil(artifact.failure)
    }

    @MainActor func testLatestPreviewRequestWinsAndCloseInvalidatesPendingLoad() async {
        let pane = PaneModel(profile: .sshConfigHost("preview.invalid"))
        let slowGate = PreviewGate(), closeGate = PreviewGate()
        let slow = pane.openPreview { await slowGate.wait(); return Self.log("/slow-a.log") }
        let fast = pane.openPreview { Self.log("/fast-b.log") }
        await fast.value
        XCTAssertEqual(pane.artifacts.last?.remotePath, "/fast-b.log")
        await slowGate.open(); await slow.value
        XCTAssertEqual(pane.artifacts.map(\.remotePath), ["/fast-b.log"], "a stale completion must not present")

        let pending = pane.openPreview { await closeGate.wait(); return Self.log("/after-close.log") }
        pane.dismissArtifact(pane.artifacts[0].id)
        await closeGate.open(); await pending.value
        XCTAssertTrue(pane.artifacts.isEmpty, "closing invalidates the in-flight request")

        let loaded = Self.log("/direct.log")
        let superseded = pane.openPreview { Self.log("/late.log") }
        pane.presentRequestedArtifact(loaded)
        await superseded.value
        XCTAssertEqual(pane.artifacts.map(\.remotePath), ["/direct.log"])
    }

    func testAttachmentPreviewReadsCapturedSnapshotNotMutableSource() async throws {
        let source = try temporaryFile(Data("captured\n".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-preview-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try RelayAgentAttachmentSnapshot.capture(source, directory: directory)
        try Data("edited after attaching\n".utf8).write(to: source)
        let artifact = await RelayFilePreviewLoader.load(snapshot: snapshot, name: "job.log", kind: .log)
        XCTAssertNil(artifact.failure)
        XCTAssertEqual(artifact.filename, "job.log")
        XCTAssertEqual(artifact.text, "captured\n")
    }

    nonisolated private static func log(_ path: String) -> PaneArtifact {
        PaneArtifact(remotePath: path, log: RelayLogTail(bytes: Data(path.utf8), totalBytes: path.utf8.count))
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor PreviewGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}
