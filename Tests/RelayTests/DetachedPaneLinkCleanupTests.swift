import XCTest
import SwiftUI
import AppKit
import Vision
@testable import Relay

final class DetachedPaneLinkCleanupTests: XCTestCase {
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    func link(_ id: String = "1", _ pair: [UUID]? = nil) -> PaneLinkMembership {
        .init(id: String(repeating: id, count: 64), paneIDs: pair ?? [a,b], unavailable: false)
    }

    func testReviewIsExactOneShotAndRejectsChangedOrReattachedPanes() {
        var state = DetachedPaneLinkCleanup()
        let first = link(), added = link("2", [b,c])
        XCTAssertTrue(state.confirm(current: [first], attached: []).isEmpty, "No unreviewed authorization")
        state.review([first], attached: [a])
        XCTAssertEqual(state.confirm(current: [first,added], attached: [a]), [first], "No newly discovered link authorized")
        XCTAssertTrue(state.confirm(current: [first], attached: []).isEmpty, "Confirmation must be consumed")
        state.review([first], attached: [a]); state.cancel()
        XCTAssertTrue(state.confirm(current: [first], attached: []).isEmpty, "Cancel revokes review")
        state.review([first], attached: [a])
        XCTAssertTrue(state.confirm(current: [first], attached: [a,b]).isEmpty, "Reattached pair protected")
        state.review([first], attached: [a])
        XCTAssertTrue(state.confirm(current: [link("1",[a,c])], attached: [a]).isEmpty, "Changed pair protected")
        XCTAssertFalse(DetachedPaneLinkCleanup.canRemove(first, current: [first,first], attached: [a]), "Ambiguous record rejected")
        XCTAssertEqual(DetachedPaneLinkCleanup.candidates([first,first], attached: [a]), [first], "Deduplicated review")
        XCTAssertTrue(DetachedPaneLinkCleanup.candidates([link("3",[a,a])], attached: []).isEmpty, "Malformed pair rejected")
    }

    func testAllOwnerAndAttachmentInterleavingsThroughSixOperations() {
        // Owner: review/cancel/confirm. Other actor: attach/detach/replace/add.
        // Enumerate all sequences, including repeated operations and ordering.
        struct Model { var reviewed: [PaneLinkMembership]?; var current: [PaneLinkMembership]; var attached: Set<UUID> }
        var visited = 0
        func visit(_ state: DetachedPaneLinkCleanup, _ model: Model, _ depth: Int) {
            visited += 1
            XCTAssertEqual(state.reviewed, model.reviewed, "Review state follows owner operations")
            guard depth > 0 else { return }
            for op in 0..<7 {
                var s = state, m = model
                switch op {
                case 0:
                    s.review(m.current, attached: m.attached)
                    m.reviewed = m.current.filter { row in row.paneIDs.contains { !m.attached.contains($0) } }
                case 1: s.cancel(); m.reviewed = nil
                case 2:
                    let expected = (m.reviewed ?? []).filter { row in
                        m.current.contains { $0.id == row.id && $0.paneIDs == row.paneIDs }
                            && row.paneIDs.contains { !m.attached.contains($0) }
                    }
                    XCTAssertEqual(s.confirm(current: m.current, attached: m.attached), expected, "Only reviewed unchanged detached links authorized")
                    m.reviewed = nil
                case 3: m.attached = [a,b,c]
                case 4: m.attached = [a]
                case 5: m.current[0] = link("1", m.current[0].paneIDs == [a,b] ? [a,c] : [a,b])
                default:
                    if m.current.count == 1 { m.current.append(link("2",[b,c])) }
                }
                visit(s,m,depth-1)
            }
        }
        visit(DetachedPaneLinkCleanup(), Model(current: [link()], attached: [a]), 6)
        XCTAssertEqual(visited, 137257)
        print("BOUNDED_CHECK states=137257 depth=6 actors=2 operations=7")
    }

    func testSeededRecordFuzzPreservesExactPairAndAttachmentBoundary() {
        var seed: UInt64 = 0xD37AC4ED
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        for _ in 0..<4096 {
            let ids = [a.uuidString,b.uuidString,"invalid","",c.uuidString]
            let members: [[String:Any]] = (0..<Int(next()%5)).map { _ in ["paneID": ids[Int(next()%5)]] }
            let record: [String:Any] = ["id": String(repeating:"a",count:64), "members": members, "state": next()%2 == 0 ? "pane_unavailable" : "membership_saved"]
            guard let row = PaneLinkMembership(record: record) else { continue }
            XCTAssertEqual(Set(row.paneIDs).count,2)
            let attached = Set([a,b,c].filter { _ in next()%2 == 0 })
            let candidates = DetachedPaneLinkCleanup.candidates([row], attached: attached)
            XCTAssertEqual(candidates.isEmpty, Set(row.paneIDs).isSubset(of: attached), "Availability cannot grant deletion of attached pair")
            if let candidate = candidates.first { XCTAssertEqual(candidate.id, row.id); XCTAssertEqual(candidate.paneIDs,row.paneIDs) }
        }
        print("SEEDED_FUZZ samples=4096 seed=0xD37AC4ED")
    }

    @MainActor func testNativeReviewRenders() throws {
        _ = NSApplication.shared
        let selection = PaneLinkSelection()
        selection.describePane = { $0 == self.a ? "Research coordinator" : "Detached analysis pane" }
        selection.cleanup.review([link()], attached: [a])
        let view = NSHostingView(rootView: DetachedPaneLinkCleanupView(selection: selection, dismiss: {}))
        view.frame = NSRect(x:0,y:0,width:600,height:480)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        XCTAssertGreaterThan(data.count,8000,"Review must render nonblank content")
        let path = ProcessInfo.processInfo.environment["CLEANUP_RENDER_PATH"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-review-" + UUID().uuidString + ".png").path
        try data.write(to:URL(fileURLWithPath:path))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(data: data).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(visible.contains("remove detached-pane links"), "Review must render nonblank content: title missing; " + visible)
        XCTAssertTrue(visible.contains("research coordinator"), "Reviewed pane name must be visible; " + visible)
        XCTAssertTrue(visible.contains("cancel") && visible.contains("remove 1"), "Native confirmation choices must be visible; " + visible)
    }
}
