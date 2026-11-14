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

    static let allShown: (PaneModel, [String], [RelayQuickLookTarget]) async -> [RelayShowItemResult] = { _, items, _ in
        items.map { RelayShowItemResult(item: $0, result: "shown", detail: nil) }
    }

    @Test func showNeedsTheNavigateGrantAndIsIdempotent() async throws {
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
        func call(_ data: Data, _ permits: @escaping (MCPWorkspaceCapability) -> Bool = { $0 == .navigate }) async -> RelaySidePanelHTTPResponse {
            await handler.show(data, instance: instance, permits: permits, workspace: workspace, check: Self.allShown, present: present)
        }
        let wire = try body(["~/plot.png", "https://example.org/"])
        #expect(await call(wire, { _ in false }).status == 403)
        #expect(await call(wire, { $0 == .layout }).status == 403) // navigate, not another capability
        #expect(shown.isEmpty)
        #expect(await call(wire).status == 200)
        #expect(await call(wire).status == 200)            // a repeat returns the saved result
        #expect(shown.count == 1)                     // and shows nothing again
        #expect(await call(try body(["/other"])).status == 409) // same ID, different request
        #expect(await call(try body(["https://example.org/"], id: UUID())).status == 200)
        #expect(shown.count == 2)

        // Refused before anything is shown.
        #expect(await call(try body(["/a"], id: UUID(), owner: UUID())).status == 400)       // stale instance
        #expect(await call(try body(["/a"], id: UUID(), target: UUID())).status == 409)      // unknown pane
        #expect(await call(try body([], id: UUID())).status == 400)
        #expect(await call(try body(Array(repeating: "/a", count: 17), id: UUID())).status == 400)
        #expect(await call(try body(["mailto:a@b.org"], id: UUID())).status == 400)
        var extra = try #require(try JSONSerialization.jsonObject(with: body(["/a"], id: UUID())) as? [String: Any])
        extra["focus"] = true
        #expect(await call(try JSONSerialization.data(withJSONObject: extra)).status == 400)
        #expect(shown.count == 2)
    }

    @Test func nothingResolvableIsReportedNotShown() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let instance = UUID()
        let data = try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: instance, requestID: UUID(), paneID: paneID, items: ["rel/x.txt"]))
        let response = await MCPDirectTabRequests().show(data, instance: instance, permits: { _ in true }, workspace: workspace,
                                                         check: Self.allShown, present: { _, _ in nil })
        let decoded = try JSONDecoder().decode(MCPDirectTabRequests.ShowResponse.self, from: response.body)
        #expect(response.status == 200 && decoded.status == "nothing_shown" && decoded.items.first?.result == "error")
    }

    @Test func aShowBouncesTheDockOnlyWhenRelayIsBehind() async throws {
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
        func call(_ items: [String], id: UUID = request, outcome: RelayShowOutcome? = .quickLook) async throws -> Int {
            let data = try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: instance, requestID: id, paneID: paneID, items: items))
            return await handler.show(data, instance: instance, permits: { _ in true }, workspace: workspace, check: Self.allShown,
                                      present: { _, _ in outcome }, attention: { asked += 1 }).status
        }
        #expect(try await call(["/a"]) == 200 && asked == 1)
        #expect(try await call(["/a"]) == 200 && asked == 1)                   // repeat
        #expect(try await call(["mailto:x@y.org"], id: UUID()) == 400 && asked == 1)
        #expect(try await call(["rel/x"], id: UUID(), outcome: nil) == 200 && asked == 1) // nothing opened
        #expect(try await call(["https://example.org/"], id: UUID(), outcome: .browser(URL(string: "https://example.org/")!)) == 200 && asked == 2)
    }

    @Test func remoteStatsMapToWhatTheUserWillSee() {
        let r = { (stat: [String: Any]?, error: String?) in RelayShowCheck.remote("x", stat: stat, error: error, maxBytes: 100).result }
        #expect(r(["size": 10, "version": "v", "directory": false], nil) == "shown")
        #expect(r(["size": 0, "version": "v", "directory": false], nil) == "shown")
        #expect(r(["size": 101, "version": "v", "directory": false], nil) == "too_large")
        #expect(r(["size": 4096, "version": "v", "directory": true], nil) == "folder")
        #expect(r(["size": 10, "directory": false], nil) == "error")           // no version: can't be read safely
        #expect(r(nil, "stat /tmp/nope: no such file or directory") == "not_found")
        #expect(r(nil, "permission denied") == "error")
        #expect(RelayShowCheck.remote("big", stat: ["size": 34603008, "version": "v", "directory": false], error: nil).result == "too_large")
        #expect(RelayShowCheck.local("a", exists: false).result == "not_found")
        #expect(RelayShowCheck.local("a", exists: true).result == "shown")
    }

    @Test func checkerResolvesWhereThePaneLives() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-show-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let items = [dir.path + "/a.txt", dir.path + "/missing.txt", "rel/x.txt", "https://example.org/", "http://localhost:5173/"]
        let targets = items.compactMap(RelayQuickLookLinks.target(fromAgentItem:))
        let local = await RelayShowCheck.run(items: items, targets: targets, location: .local(cwd: nil))
        #expect(local.map(\.result) == ["shown", "not_found", "unresolved", "shown", "shown"])
        // URLs alone: the first opens in the browser, even a remote pane's localhost.
        let urls = ["http://localhost:5173/", "https://example.org/"]
        let remote = ConnectionProfile(name: "q", kind: .ssh, host: "q.invalid", backend: .relay)
        let browser = await RelayShowCheck.run(items: urls, targets: urls.compactMap(RelayQuickLookLinks.target(fromAgentItem:)),
                                               location: .remote(remote, cwd: "/h"))
        #expect(browser.map(\.result) == ["shown", "unresolved"])
        let unreadable = await RelayShowCheck.run(items: items, targets: targets, location: .unreadable)
        #expect(unreadable.map(\.result) == ["unresolved", "unresolved", "unresolved", "shown", "unresolved"])
    }

    /// Only items that will display are shown; every item is reported.
    @Test func onlyShowableItemsOpenAndAllAreReported() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let instance = UUID()
        let items = ["/h/note.md", "/h/big.bin", "/h/sub/", "/h/gone.txt"]
        let verdicts = ["shown", "too_large", "folder", "not_found"]
        var presented: [[RelayQuickLookTarget]] = []
        var bounced = 0
        let data = try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: instance, requestID: UUID(), paneID: paneID, items: items))
        let response = await MCPDirectTabRequests().show(data, instance: instance, permits: { _ in true }, workspace: workspace,
            check: { _, items, _ in zip(items, verdicts).map { RelayShowItemResult(item: $0.0, result: $0.1, detail: nil) } },
            present: { _, targets in presented.append(targets); return .quickLook }, attention: { bounced += 1 })
        let decoded = try JSONDecoder().decode(MCPDirectTabRequests.ShowResponse.self, from: response.body)
        #expect(presented == [[.path("/h/note.md")]])
        #expect(decoded.status == "shown" && decoded.surface == "quick_look")
        #expect(decoded.items.map(\.result) == verdicts && decoded.items.map(\.item) == items)
        #expect(bounced == 1)

        // Nothing showable: no window, no bounce, still a full report.
        let none = try JSONEncoder().encode(MCPDirectTabRequests.ShowProposal(instance: instance, requestID: UUID(), paneID: paneID, items: ["/h/big.bin"]))
        let quiet = await MCPDirectTabRequests().show(none, instance: instance, permits: { _ in true }, workspace: workspace,
            check: { _, items, _ in items.map { RelayShowItemResult(item: $0, result: "too_large", detail: nil) } },
            present: { _, targets in presented.append(targets); return .quickLook }, attention: { bounced += 1 })
        let q = try JSONDecoder().decode(MCPDirectTabRequests.ShowResponse.self, from: quiet.body)
        #expect(q.status == "nothing_shown" && q.surface == nil && q.items.map(\.result) == ["too_large"])
        #expect(presented.count == 1 && bounced == 1)
    }
}
