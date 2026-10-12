import AppKit
import Testing
@testable import Relay

@Test @MainActor func editorMCPApprovalRequiresConsentAndPreventsReplay() async throws {
    var answer: ((NSApplication.ModalResponse) -> Void)?
    var presentations = 0
    let control = EditorMCPControl(present: { _, completion in
        presentations += 1
        answer = completion
        return true
    })
    let id = UUID()
    var edits = 0
    let apply: @MainActor () async throws -> [String: Any] = {
        edits += 1
        return ["status": "edited"]
    }
    let receipt = try control.propose(id: id, fingerprint: "exact", path: "/tmp/test.R",
        preview: "λ", saving: false, apply: apply)
    #expect(receipt["status"] as? String == "pending")
    #expect(edits == 0)
    answer?(.alertFirstButtonReturn)
    for _ in 0..<10 { await Task.yield() }
    #expect(control.receipt(id)?["status"] as? String == "edited")
    _ = try control.propose(id: id, fingerprint: "exact", path: "/tmp/test.R",
        preview: "λ", saving: false, apply: apply)
    #expect(edits == 1)
    #expect(presentations == 1)
    #expect(throws: (any Error).self) {
        try control.propose(id: id, fingerprint: "different", path: "/tmp/test.R",
            preview: "λ", saving: false, apply: apply)
    }
    let denied = UUID()
    _ = try control.propose(id: denied, fingerprint: "deny", path: "/tmp/test.R",
        preview: "", saving: true, apply: apply)
    answer?(.alertSecondButtonReturn)
    #expect(control.receipt(denied)?["status"] as? String == "denied")
    #expect(edits == 1)
}
