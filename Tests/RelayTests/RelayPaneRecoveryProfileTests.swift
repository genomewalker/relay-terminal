import AppKit
import Foundation
import Testing
@testable import Relay

@Test("Existing pane recovery uses its exact captured profile, never a same-label replacement")
func recoveryCapturedProfile() {
    let original = ConnectionProfile.sshConfigHost("dandy-07")
    let newlyResolved = ConnectionProfile.sshConfigHost("dandy-07")
    #expect(original.id != newlyResolved.id)
    #expect(RelayPaneRecoveryProfile.captured(original, requestedHost: "dandy-07") == original)
    #expect(RelayPaneRecoveryProfile.captured(original, requestedHost: "dandy") == nil)
    var direct = original
    direct.backend = .direct
    #expect(RelayPaneRecoveryProfile.captured(direct, requestedHost: "dandy-07") == nil)
    #expect(RelayPaneRecoveryProfile.captured(.local, requestedHost: "This Mac") == .local)
    #expect(RelayPaneRecoveryProfile.captured(.local, requestedHost: "dandy-07") == nil)
}

@Test("Recovery ownership gate holds across bounded two-actor changes")
@MainActor
func recoveryOwnershipBounded() {
    // The real gate is exercised after every prefix. Actor A captures/commits;
    // actor B can remove, replace, mutate or restore the pane profile. Depth 5
    // enumerates every ordered operation sequence from each initial state.
    let original = ConnectionProfile.sshConfigHost("dandy-07")
    var changed = original
    changed.user = "different-user"
    let first = PaneModel(profile: original)
    let replacement = PaneModel(id: first.id, profile: original)
    let otherHost = PaneModel(id: first.id, profile: changed)
    struct State { var captured: PaneModel?; var current: PaneModel? }
    var explored = 0
    var states: Set<String> = []
    func walk(_ state: State, _ depth: Int) {
        explored += 1
        func label(_ pane: PaneModel?) -> String {
            if pane === first { return "first" }
            if pane === replacement { return "replacement" }
            if pane === otherHost { return "other" }
            return "nil"
        }
        let key = label(state.captured) + "/" + label(state.current)
        states.insert(key)
        let allowed = RelayPaneRecoveryCapture(state.captured).unchanged(current: state.current)
        let expected = state.captured === state.current
        #expect(allowed == expected)
        guard depth < 5 else { return }
        // Six choices represent either actor: capture, remove, replace with
        // same-profile pane, mutate, restore same pane, and no-op/commit.
        var next = state
        next.captured = state.current
        walk(next, depth + 1)
        next = state; next.current = nil; walk(next, depth + 1)
        next = state; next.current = replacement; walk(next, depth + 1)
        next = state; next.current = otherHost; walk(next, depth + 1)
        next = state; next.current = first; walk(next, depth + 1)
        walk(state, depth + 1)
    }
    walk(State(captured: first, current: first), 0)
    walk(State(captured: nil, current: nil), 0)
    #expect(explored == 18_662)
    print("Relay pane recovery ownership bounded: depth=5 operations=6 prefixes=\(explored) unique_states=\(states.count)")
}

@Test("Recovery refuses replacement or insertion while the catalog lookup is suspended")
@MainActor
func recoveryLookupInterleavings() async throws {
    let profile = ConnectionProfile.sshConfigHost("dandy-07")
    let pane = PaneModel(profile: profile)
    let replacement = PaneModel(id: pane.id, profile: profile)
    var current: PaneModel? = pane
    var attachments = 0
    let captured = RelayPaneRecoveryCapture(pane)
    let value = try await captured.transact(current: { current }, load: { 42 }, apply: { value in
        attachments += 1
        return value
    })
    #expect(value == 42)
    #expect(attachments == 1)
    var permitted = true
    current = pane
    do {
        _ = try await captured.transact(current: { current }, permitted: { permitted }, load: {
            permitted = false
            await Task.yield()
            return 42
        }, apply: { value in attachments += 1; return value })
        Issue.record("lookup accepted a revoked grant")
    } catch is RelayPaneRecoveryCapture.Revoked {
        // Revocation is checked on the main actor immediately before attach.
    }
    #expect(attachments == 1)
    for after in [replacement, nil] as [PaneModel?] {
        current = pane
        do {
            _ = try await captured.transact(current: { current }, load: {
                current = after
                await Task.yield()
                return 42
            }, apply: { value in attachments += 1; return value })
            Issue.record("lookup accepted a changed pane")
        } catch is RelayPaneRecoveryCapture.Changed {
            // The original request must fail before attach.
        }
        #expect(attachments == 1)
    }
    let missing = RelayPaneRecoveryCapture(nil)
    current = nil
    do {
        _ = try await missing.transact(current: { current }, load: {
            current = pane
            await Task.yield()
            return 42
        }, apply: { value in attachments += 1; return value })
        Issue.record("lookup accepted a newly inserted pane")
    } catch is RelayPaneRecoveryCapture.Changed {
        // A pane created during lookup is not the one the request captured.
    }
    #expect(attachments == 1)
}

@Test("Recovery checks permission at commit across bounded grant changes")
@MainActor
func recoveryGrantBounded() async throws {
    let pane = PaneModel(profile: .sshConfigHost("dandy-07"))
    let capture = RelayPaneRecoveryCapture(pane)
    var prefixes = 0
    // The lookup actor may observe a grant/revoke sequence before it resumes.
    // Enumerate both operations through depth five, plus every prefix.
    func walk(_ changes: [Bool]) async throws {
        var allowed = true
        var attached = false
        do {
            _ = try await capture.transact(current: { pane }, permitted: { allowed }, load: {
                for change in changes { allowed = change; await Task.yield() }
                return 1
            }, apply: { value in attached = true; return value })
        } catch is RelayPaneRecoveryCapture.Revoked {}
        #expect(attached == allowed)
        prefixes += 1
        if changes.count < 5 {
            try await walk(changes + [true])
            try await walk(changes + [false])
        }
    }
    try await walk([])
    #expect(prefixes == 63)
    print("Relay recovery grant bounded: depth=5 operations=2 prefixes=\(prefixes) grant_states=2")
}

@Test("Recovery uses the catalog session when selection changes during lookup")
@MainActor
func recoveryPlacementIgnoresSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = WorkspaceModel(restoreSavedWorkspace: false,
                                   recoveryStore: RelayRecoveryStore(directory: directory))
    defer { workspace.shutdown() }
    let profile = ConnectionProfile.sshConfigHost("recovery-test-host")
    func pane(_ id: UUID, _ session: UUID, _ tab: UUID) -> RemoteCatalogPane {
        RemoteCatalogPane(paneID: id.uuidString.lowercased(), workspaceID: session.uuidString.lowercased(),
            tabID: tab.uuidString.lowercased(), parentPaneID: nil, title: "fixture", contentKind: "terminal",
            command: nil, directory: nil, state: "running", workerPID: 42, shellPID: 43,
            lastSequence: 0, recoverable: true, unfiled: false)
    }
    let firstSession = UUID(), secondSession = UUID(), catalogSession = UUID()
    let firstTab = UUID(), secondTab = UUID(), targetTab = UUID(), targetPane = UUID()
    for (session, tab) in [(firstSession, firstTab), (secondSession, secondTab)] {
        workspace.attachRemoteSession(profile: profile, remote: RemoteSessionRecord(
            id: "workspace:\(session.uuidString.lowercased())", workspaceID: session.uuidString.lowercased(),
            panes: [pane(UUID(), session, tab)], workspaceSnapshot: nil))
    }
    workspace.selectTab(firstTab)
    let capture = RelayPaneRecoveryCapture(nil)
    let attached = try await capture.transact(current: { workspace.panes[targetPane] }, load: {
        workspace.selectTab(secondTab)
        await Task.yield()
        return pane(targetPane, catalogSession, targetTab)
    }, apply: { pane in
        RelayPaneRecoveryAttachment.attach(workspace: workspace, profile: profile, pane: pane, sessionLabel: "fixture")
    })
    #expect(attached)
    #expect(workspace.tabs.first(where: { $0.id == targetTab })?.sessionID == catalogSession)
}

@Test("Recovery authorization follows real grant and caller changes")
@MainActor
func recoveryRealAuthorizationBounded() async throws {
    try #require(RelayStateProfile.isIsolated, "Authorization fixture requires isolated defaults")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var prefixes = 0
    func check(_ operations: [Int]) async throws {
        var complete: ((NSApplication.ModalResponse) -> Void)?
        let grant = MCPWorkspaceGrant { _, callback in complete = callback; return true }
        let callers = RelayCallerControl(directory: root.appendingPathComponent(UUID().uuidString))
        let issued = try await callers.register(label: "recovery-fixture", thread: nil)
        let caller = try #require(issued["caller_id"])
        var granted = false, paused = false
        func assertPolicy() {
            #expect(RelayPaneRecoveryAuthorization.permits(grant: grant, callers: callers, caller: caller) == (granted && !paused))
            #expect(!RelayPaneRecoveryAuthorization.permits(grant: grant, callers: callers, caller: nil))
        }
        assertPolicy()
        for op in operations {
            switch op {
            case 0:
                if !granted { try grant.request(); complete?(.alertSecondButtonReturn); granted = true }
            case 1: grant.revoke(); granted = false
            case 2: try await callers.setPaused(id: caller, paused: true); paused = true
            default: try await callers.setPaused(id: caller, paused: false); paused = false
            }
            assertPolicy()
        }
        let capture = RelayPaneRecoveryCapture(nil)
        var attached = false
        do {
            _ = try await capture.transact(current: { nil }, permitted: {
                RelayPaneRecoveryAuthorization.permits(grant: grant, callers: callers, caller: caller)
            }, load: { await Task.yield(); return 1 }, apply: { value in attached = true; return value })
        } catch is RelayPaneRecoveryCapture.Revoked {}
        #expect(attached == (granted && !paused))
        prefixes += 1
        if operations.count < 3 {
            for op in 0..<4 { try await check(operations + [op]) }
        }
    }
    try await check([])
    #expect(prefixes == 85)
    print("Relay recovery real authorization bounded: depth=3 operations=4 prefixes=\(prefixes) policy_states=4")
}

@Test("Recovery receipts prevent duplicate concurrent dispatch and conflicting replay")
@MainActor
func recoveryReceiptsBounded() {
    let id = UUID(), pane = UUID(), instance = UUID()
    let request = MCPRecoverPaneRequest(instance: instance, requestID: id, host: "dandy-07", paneID: pane)
    let conflicting = MCPRecoverPaneRequest(instance: instance, requestID: id, host: "dandy", paneID: pane)
    let result = ["status": "attached"]
    var prefixes = 0
    var states: Set<String> = []
    func check(_ operations: [Int]) {
        let receipts = RelayPaneRecoveryReceipts()
        var running = [false, false]
        var done = false
        for op in operations {
            switch op {
            case 0, 1:
                let actor = op
                guard !running[actor] else { break }
                switch receipts.begin(request) {
                case .started:
                    #expect(!running[1 - actor] && !done, "duplicate dispatch")
                    running[actor] = true
                case .pending:
                    #expect(running[1 - actor] && !done)
                case .replay(let saved):
                    #expect(done && saved == result)
                case .conflict, .full:
                    Issue.record("same request unexpectedly refused")
                }
            case 2, 3:
                let actor = op - 2
                if running[actor] {
                    #expect(receipts.finish(request, result: result))
                    running[actor] = false
                    done = true
                }
            case 4, 5:
                let actor = op - 4
                if running[actor] { receipts.cancel(request); running[actor] = false }
            default:
                if running[0] || running[1] || done { #expect(receipts.begin(conflicting) == .conflict) }
            }
            #expect(!(running[0] && running[1]), "two owners for one request ID")
            states.insert("\(running[0])/\(running[1])/\(done)")
        }
    }
    func walk(_ prefix: [Int]) {
        prefixes += 1
        check(prefix)
        guard prefix.count < 5 else { return }
        for op in 0..<7 { walk(prefix + [op]) }
    }
    walk([])
    #expect(prefixes == 19_608)
    print("Relay pane recovery receipts bounded: depth=5 operations=7 prefixes=\(prefixes) unique_states=\(states.count)")
}
