import Foundation
import Testing
@testable import Relay

@Suite("relay_show", .serialized)
@MainActor struct RelayShowTests {
    @Test func agentItemsArePathsOrWebURLsOnly() {
        #expect(RelayQuickLookLinks.target(fromAgentItem: "~/run/plot.png") == .path("~/run/plot.png"))
        #expect(RelayQuickLookLinks.target(fromAgentItem: "sub/") == .path("sub/"))       // folders reach the host's refusal
        #expect(RelayQuickLookLinks.target(fromAgentItem: "results") == .path("results"))  // no extension needed
        #expect(RelayQuickLookLinks.target(fromAgentItem: "https://example.org/a") == .web(URL(string: "https://example.org/a")!))
        for refused in ["mailto:a@b.org", "file:///etc/hosts", "javascript:alert(1)", "relay:x", "https://u:p@example.org/",
                        "a\nb", "", "x-man-page://ls"] {
            #expect(RelayQuickLookLinks.target(fromAgentItem: refused) == nil, "\(refused)")
        }
    }

    @Test func showNeedsTheNavigateGrantAndIsIdempotent() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let instance = UUID(), request = UUID()
        let handler = MCPDirectTabRequests()
        var shown: [[RelayQuickLookTarget]] = []
        let present: (PaneModel, [RelayQuickLookTarget]) -> RelayShowOutcome? = { pane, targets in
            #expect(pane.id == paneID)
            shown.append(targets)
            return targets.contains { if case .path = $0 { true } else { false } } ? .quickLook : .browser(URL(string: "https://example.org/")!)
        }
        func body(_ items: [String], id: UUID? = nil, target: UUID? = nil, owner: UUID? = nil) throws -> Data {
            try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: owner ?? instance, requestID: id ?? request,
                                                                       paneID: target ?? paneID, items: items))
        }
        func call(_ data: Data, _ permits: @escaping (MCPWorkspaceCapability) -> Bool = { $0 == .navigate }) -> RelaySidePanelHTTPResponse {
            handler.show(data, instance: instance, permits: permits, workspace: workspace, present: present)
        }
        let wire = try body(["~/plot.png", "https://example.org/"])
        #expect(call(wire, { _ in false }).status == 403)
        #expect(call(wire, { $0 == .layout }).status == 403) // navigate, not another capability
        #expect(shown.isEmpty)
        #expect(call(wire).status == 200)
        #expect(call(wire).status == 200)            // a repeat returns the saved result
        #expect(shown.count == 1)                     // and shows nothing again
        #expect(call(try body(["/other"])).status == 409) // same ID, different request
        #expect(call(try body(["https://example.org/"], id: UUID())).status == 200)
        #expect(shown.count == 2)

        // Refused before anything is shown.
        #expect(call(try body(["/a"], id: UUID(), owner: UUID())).status == 400)       // stale instance
        #expect(call(try body(["/a"], id: UUID(), target: UUID())).status == 409)      // unknown pane
        #expect(call(try body([], id: UUID())).status == 400)
        #expect(call(try body(Array(repeating: "/a", count: 17), id: UUID())).status == 400)
        #expect(call(try body(["mailto:a@b.org"], id: UUID())).status == 400)
        var extra = try #require(try JSONSerialization.jsonObject(with: body(["/a"], id: UUID())) as? [String: Any])
        extra["focus"] = true
        #expect(call(try JSONSerialization.data(withJSONObject: extra)).status == 400)
        #expect(shown.count == 2)
    }

    @Test func nothingResolvableIsAConflictNotASuccess() throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let instance = UUID()
        let data = try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: instance, requestID: UUID(), paneID: paneID, items: ["rel/x.txt"]))
        let response = MCPDirectTabRequests().show(data, instance: instance, permits: { _ in true }, workspace: workspace,
                                                   present: { _, _ in nil })
        #expect(response.status == 409)
    }

    @Test func aShowBouncesTheDockOnlyWhenRelayIsBehind() throws {
        var bounces = 0
        #expect(RelayShowAttention.request(isActive: true, bounce: { bounces += 1 }) == false)
        #expect(RelayShowAttention.request(isActive: false, bounce: { bounces += 1 }) == true)
        #expect(bounces == 1)

        // Once per new show: not for a repeat or a refusal.
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let instance = UUID(), request = UUID()
        let handler = MCPDirectTabRequests()
        var asked = 0
        func call(_ items: [String], id: UUID = request, outcome: RelayShowOutcome? = .quickLook) throws -> Int {
            let data = try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: instance, requestID: id, paneID: paneID, items: items))
            return handler.show(data, instance: instance, permits: { _ in true }, workspace: workspace,
                                present: { _, _ in outcome }, attention: { asked += 1 }).status
        }
        #expect(try call(["/a"]) == 200 && asked == 1)
        #expect(try call(["/a"]) == 200 && asked == 1)                   // repeat
        #expect(try call(["mailto:x@y.org"], id: UUID()) == 400 && asked == 1)
        #expect(try call(["rel/x"], id: UUID(), outcome: nil) == 409 && asked == 1)
        #expect(try call(["https://example.org/"], id: UUID(), outcome: .browser(URL(string: "https://example.org/")!)) == 200 && asked == 2)
    }
}
