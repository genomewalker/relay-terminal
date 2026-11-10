import AppKit
import Foundation
import Testing
@testable import Relay

/// The overview facts behind the sidebar, fleet board, tab rail and Go to pane
/// are reused per pane. Reuse must never change a result: after every kind of
/// change the cached pass equals a full recomputation (`cache: nil`).
@MainActor @Suite("Pane fact cache equals a full recomputation")
struct RelayPaneFactCacheTests {
    private typealias Index = RelayWorkOverviewIndex

    private static func send(_ pane: PaneModel, _ event: String, _ id: String) {
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"\#(event)","tool_name":"Bash","event_id":"\#(id)"}}"#.utf8))
    }

    private static func open(_ workspace: WorkspaceModel, _ name: String) throws -> PaneModel {
        workspace.newTab(profile: .sshConfigHost("fact-cache-\(name).invalid"))
        let pane = try #require(workspace.activePane)
        pane.connectionState = .connected
        return pane
    }

    private static func expectEquivalent(_ workspace: WorkspaceModel, _ step: String,
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        let cached = Index.paneFacts(workspace)
        let full = Index.paneFacts(workspace, cache: nil)
        #expect(cached == full, "after \(step)", sourceLocation: sourceLocation)
        // A second cached pass with nothing changed is the same again.
        #expect(Index.paneFacts(workspace) == full, "repeat after \(step)", sourceLocation: sourceLocation)
    }

    @Test("Cached facts equal a full recomputation across pane and tab changes")
    func equivalence() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.relayIsFrontmost = { true }
        defer { workspace.shutdown() }
        let a = try Self.open(workspace, "a"), b = try Self.open(workspace, "b"), c = try Self.open(workspace, "c")
        defer { for pane in [a, b, c] { AgentIntelligenceStore.shared.markPaneRead(pane.id) } }
        Self.expectEquivalent(workspace, "open")

        Self.send(a, "PreToolUse", "fact-cache-run-\(a.id)")
        Self.expectEquivalent(workspace, "phase active")
        Self.send(b, "PermissionRequest", "fact-cache-wait-\(b.id)")
        Self.expectEquivalent(workspace, "approval wait")
        #expect(Index.paneFacts(workspace).first { $0.paneID == b.id }?.status == .waiting)

        c.connectionState = .reconnecting("link")
        Self.expectEquivalent(workspace, "reconnecting")
        c.connectionState = .disconnected("Host unreachable")
        Self.expectEquivalent(workspace, "disconnected")
        c.connectionState = .connected
        c.isRestoringTerminal = true
        Self.expectEquivalent(workspace, "restoring")
        c.isRestoringTerminal = false

        let records = try JSONDecoder().decode([RelayProgramStatusRecord].self,
                                               from: Data(#"[{"state":"error","title":"Build failed"}]"#.utf8))
        a.applyProgramStatus(RelayStatus(state: "program_status", programStatus: records, programStatusRevision: 1,
                                         programStatusReplay: true), deliveryEpoch: UUID())
        Self.expectEquivalent(workspace, "program report")
        a.exited(exitCode: 2)
        Self.expectEquivalent(workspace, "failed exit")
        #expect(Index.paneFacts(workspace).first { $0.paneID == a.id }?.status == .failed)

        b.customName = "renamed pane"
        Self.expectEquivalent(workspace, "pane renamed")
        b.title = "new title"
        Self.expectEquivalent(workspace, "title")
        try workspace.renameTab(try #require(workspace.tabID(containingPane: c.id)), to: "renamed tab")
        Self.expectEquivalent(workspace, "tab renamed")

        // Added: a new tab, and a stacked pane that hides its sibling.
        let d = try Self.open(workspace, "d")
        Self.expectEquivalent(workspace, "pane added")
        let stacked = try workspace.newStackedPane(onto: d.id, profile: .sshConfigHost("fact-cache-e.invalid"))
        Self.expectEquivalent(workspace, "stacked (hidden member)")
        workspace.selectStackMember(d.id)
        Self.expectEquivalent(workspace, "stack member selected")
        try workspace.unstackPane(stacked.paneID)
        Self.expectEquivalent(workspace, "unstacked (moved)")

        // Removed.
        workspace.selectTab(try #require(workspace.tabID(containingPane: d.id)), origin: .user)
        workspace.closeActivePane()
        Self.expectEquivalent(workspace, "pane removed")
        #expect(workspace.paneFactCache.count == Index.paneFacts(workspace).count)
    }

    @Test("Only changed panes are recomputed")
    func unchangedPaneIsReused() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.relayIsFrontmost = { true }
        defer { workspace.shutdown() }
        let a = try Self.open(workspace, "reuse-a"), b = try Self.open(workspace, "reuse-b")
        defer { for pane in [a, b] { AgentIntelligenceStore.shared.markPaneRead(pane.id) } }
        let cache = Index.PaneFactCache()
        let first = Index.paneFacts(workspace, cache: cache)
        let base = cache.computed
        #expect(base == first.count)

        // Nothing changed: every fact is reused.
        #expect(Index.paneFacts(workspace, cache: cache) == first)
        #expect(cache.computed == base)

        // Only `a` changed: exactly one fact is recomputed.
        a.connectionState = .reconnecting("link")
        let second = Index.paneFacts(workspace, cache: cache)
        #expect(cache.computed == base + 1)
        #expect(second == Index.paneFacts(workspace, cache: nil))

        // Time passing alone changes nothing: `paneFact` reads no clock, and
        // relative labels ("4 min ago") are formed from `changedAt` at render.
        Self.send(b, "PreToolUse", "fact-cache-time-\(b.id)")
        let withActivity = Index.paneFacts(workspace, cache: cache)
        let afterActivity = cache.computed
        let changedAt = try #require(withActivity.first { $0.paneID == b.id }?.changedAt)
        #expect(Index.paneFacts(workspace, cache: cache) == Index.paneFacts(workspace, cache: nil))
        #expect(cache.computed == afterActivity)
        #expect(Index.changeLabel(changedAt, now: changedAt.addingTimeInterval(2 * 3600)) == "2 h ago")
    }

    @Test("A replacement pane with the same id is not served the old fact")
    func replacementPaneRecomputes() {
        let id = UUID()
        let cache = Index.PaneFactCache()
        let tab = UUID()
        let old = PaneModel(id: id, profile: .sshConfigHost("fact-cache-old.invalid"))
        old.connectionState = .disconnected("gone")
        let oldFact = cache.fact(old, tabID: tab, workspaceName: "W", tabName: "t", hidden: false)
        cache.endPass()
        let replacement = PaneModel(id: id, profile: .sshConfigHost("fact-cache-new.invalid"))
        replacement.connectionState = .connected
        let newFact = cache.fact(replacement, tabID: tab, workspaceName: "W", tabName: "t", hidden: false)
        #expect(cache.computed == 2)
        #expect(newFact != oldFact)
        #expect(newFact == Index.paneFact(replacement, tabID: tab, workspaceName: "W", tabName: "t", hidden: false))
    }

    @Test("Measure: 150 panes per pass, full vs cached (printed, not asserted)")
    func measure() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var panes: [PaneModel] = []
        for index in 0..<150 { panes.append(try Self.open(workspace, "measure-\(index)")) }
        defer { for pane in panes { AgentIntelligenceStore.shared.markPaneRead(pane.id) } }
        for (index, pane) in panes.enumerated() where index.isMultiple(of: 3) {
            Self.send(pane, "PreToolUse", "fact-cache-measure-\(pane.id)")
        }
        let passes = 200
        let clock = ContinuousClock()
        var sink = 0
        let full = clock.measure {
            for _ in 0..<passes { sink &+= Index.paneFacts(workspace, cache: nil).count }
        }
        let cache = Index.PaneFactCache()
        _ = Index.paneFacts(workspace, cache: cache)
        let cached = clock.measure {
            for _ in 0..<passes { sink &+= Index.paneFacts(workspace, cache: cache).count }
        }
        // A realistic tick: a few panes changed since the last pass.
        let fewChanged = clock.measure {
            for pass in 0..<passes {
                for pane in panes[(pass % 50)..<((pass % 50) + 3)] {
                    pane.connectionState = pane.connectionState == .connected ? .reconnecting("m") : .connected
                }
                sink &+= Index.paneFacts(workspace, cache: cache).count
            }
        }
        func perPass(_ duration: Duration) -> String {
            let micros = Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
            return String(format: "%.1f µs", micros / Double(passes))
        }
        print("pane facts, \(panes.count) panes per pass: full \(perPass(full)), cached unchanged \(perPass(cached)), cached with 3 changed \(perPass(fewChanged)) (sink \(sink))")
        #expect(sink > 0)
    }
}
