import Foundation
import Testing
@testable import Relay

@Test("Plan state rejects stale, replayed and wrong-session events")
func agentPlanEventIdentity() {
    var state = RelayAgentPlanState(sessionID: "codex-1", connectionGeneration: 2)
    let wrongSession = state.apply(sessionID: "claude-1", generation: 2, sequence: 1, mode: .execute, revision: "r1")
    let stale = state.apply(sessionID: "codex-1", generation: 1, sequence: 1, mode: .execute, revision: "r1")
    let accepted = state.apply(sessionID: "codex-1", generation: 2, sequence: 1, mode: .plan, revision: "r1")
    let replay = state.apply(sessionID: "codex-1", generation: 2, sequence: 1, mode: .execute, revision: "r1")
    #expect(!wrongSession)
    #expect(!stale)
    #expect(accepted)
    #expect(!replay)
    #expect(state.mode == .plan)
}

@Test("A plan is never authority to run R or terminal input")
func agentPlanExecutionGate() {
    let pane = UUID(), request = UUID(), now = Date(timeIntervalSince1970: 100)
    let grant = RelayAgentExecutionGrant(paneID: pane, sessionID: "s", connectionGeneration: 1,
        planRevision: "r1", requestID: request, expiresAt: now.addingTimeInterval(60))
    var state = RelayAgentPlanState(sessionID: "s", connectionGeneration: 1)
    #expect(!state.allowsExecution(grant: grant, paneID: pane, requestID: request, now: now))
    state.apply(sessionID: "s", generation: 1, sequence: 1, mode: .plan, revision: "r1")
    #expect(!state.allowsExecution(grant: grant, paneID: pane, requestID: request, now: now))
    state.apply(sessionID: "s", generation: 1, sequence: 2, mode: .execute, revision: "r1")
    #expect(state.allowsExecution(grant: grant, paneID: pane, requestID: request, now: now))
    #expect(!state.allowsExecution(grant: nil, paneID: pane, requestID: request, now: now))
    #expect(!state.allowsExecution(grant: grant, paneID: UUID(), requestID: request, now: now))
    #expect(!state.allowsExecution(grant: grant, paneID: pane, requestID: UUID(), now: now))
    #expect(!state.allowsExecution(grant: grant, paneID: pane, requestID: request, now: now.addingTimeInterval(60)))
    state.apply(sessionID: "s", generation: 1, sequence: 3, mode: .execute, revision: "r2")
    #expect(!state.allowsExecution(grant: grant, paneID: pane, requestID: request, now: now))
}
