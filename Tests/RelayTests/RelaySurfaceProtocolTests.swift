import Foundation
import Testing
import AppKit
import CryptoKit
@testable import Relay

private func surfaceOwner() -> RelaySurfaceOwner {
    .init(paneID: UUID(), host: "This Mac", session: "session", producer: "native-R")
}
@Test func surfacesRejectWrongOwnerAndStaleRevision() throws {
    let owner = surfaceOwner(), id = UUID(), generation = UUID()
    let event = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation,
        revision: 1, expectedRevision: 0, operation: .snapshot, content: .table([["x"], ["1"]]))
    var state = RelaySurfaceState()
    #expect(throws: (any Error).self) { try state.apply(event, authorizedOwner: surfaceOwner()) }
    try state.apply(event, authorizedOwner: owner)
    try state.apply(event, authorizedOwner: owner)
    #expect(state.snapshots.count == 1)
    let stale = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation,
        revision: 1, expectedRevision: 0, operation: .snapshot, content: .init(kind: .text, text: "different"))
    #expect(throws: (any Error).self) { try state.apply(stale, authorizedOwner: owner) }
    let restored = try RelaySurfaceState.restore(state.checkpoint(), authorizedOwners: [owner])
    #expect(restored.snapshots == state.snapshots)
}
@Test func surfacesClosedTombstonesSurviveRestore() throws {
    let owner = surfaceOwner(), id = UUID(), generation = UUID()
    var state = RelaySurfaceState()
    let start = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation,
        revision: 1, expectedRevision: 0, operation: .snapshot, content: .init(kind: .status, title: "Agent", status: "Working"))
    try state.apply(start, authorizedOwner: owner)
    let close = RelaySurfaceEvent(schema: 1, surfaceID: id, owner: owner, generation: generation,
        revision: 2, expectedRevision: 1, operation: .close, content: nil)
    try state.apply(close, authorizedOwner: owner)
    var restored = try RelaySurfaceState.restore(state.checkpoint(), authorizedOwners: [owner])
    #expect(restored.snapshots.isEmpty)
    #expect(throws: (any Error).self) { try restored.apply(start, authorizedOwner: owner) }
}
@Test func surfacesBoundAndValidateTableShape() {
    #expect(throws: (any Error).self) { try RelaySurfaceContent.table([["x"], ["1", "2"]]).validate() }
    #expect(throws: (any Error).self) { try RelaySurfaceContent(kind: .text, text: String(repeating: "x", count: 262145)).validate() }
}

@Test func richSurfacesDecodeLegacyAndBoundProducerInput() throws {
    let legacy = try JSONDecoder().decode(RelaySurfaceContent.self,
        from: Data(#"{"kind":"text","title":"","text":"old","status":"","columns":[],"rows":[]}"#.utf8))
    try legacy.validate()
    #expect(legacy.imageBase64 == nil)
    for kind in [RelaySurfaceContent.Kind.markdown, .equation, .diagram] {
        try RelaySurfaceContent(kind: kind, text: kind == .diagram ? "graph LR; A-->B" : "x^2").validate()
    }
    for source in ["%%{init:{}}%%\ngraph LR; A-->B", "graph LR; click A https://example.com", "graph LR; A[<script>]"] {
        #expect(throws: (any Error).self) { try RelaySurfaceContent(kind: .diagram, text: source).validate() }
    }
    #expect(throws: (any Error).self) {
        try RelaySurfaceContent(kind: .text, imageBase64: "abc").validate()
    }
}

@Test func richImageSurfacesRequireValidBytesAndHash() throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    var content = RelaySurfaceContent(kind: .image, imageBase64: data.base64EncodedString(), imageSHA256: hash)
    try content.validate()
    content.imageSHA256 = "wrong"
    #expect(throws: (any Error).self) { try content.validate() }
    content.imageBase64 = String(repeating: "x", count: 900001)
    #expect(throws: (any Error).self) { try content.validate() }
}

@Test func detectsCodexDisplayedMermaidAndDelimitedEquations() {
    let viewport = """
    • Diagram
      graph TD
          User["You"] --> Broker["Manager broker"]
          Broker <--> Memory["Chitta memory"]

    $$x^2 + \\frac{1}{2}$$
    \\[E=mc^2\\]
    """
    let contents = RelayRichContentDetector.detect(viewport)
    #expect(contents.contains { $0.kind == .diagram && $0.text.contains("Broker <--> Memory") })
    #expect(contents.filter { $0.kind == .equation }.count == 2)
    #expect(RelayRichContentDetector.detect("ordinary terminal output").isEmpty)
    #expect(RelayRichContentDetector.detect("```mermaid\ngraph LR; A-->B\n```").contains { $0.kind == .diagram })
    #expect(TerminalLinkResolver.target(from: "/tmp/example.pdf") == .image("/tmp/example.pdf"))
}

@Test func inlineRichContentPreservesPhysicalSourceRowAnchors() {
    let rows = ["prompt", "", "graph LR", " A-->B", " B<-->C", "", "$$", "x^2 + 1", "$$", "next prompt"]
    let regions = RelayInlineRichRegion.detect(rows: rows, cellSize: CGSize(width: 7, height: 14), columns: 80)
    #expect(regions.count == 2)
    #expect(regions.first?.startRow == 2)
    #expect(regions.first?.rowCount == 3)
    #expect(regions.last?.startRow == 6)
    #expect(regions.last?.rowCount == 3)
    let scrolled = RelayInlineRichRegion.detect(rows: Array(rows.dropFirst()), cellSize: CGSize(width: 7, height: 14), columns: 80)
    #expect(scrolled.first?.startRow == 1)
    #expect(RelayInlineRichRegion.detect(rows: ["ordinary output"], cellSize: CGSize(width: 7, height: 14), columns: 80).isEmpty)
}
