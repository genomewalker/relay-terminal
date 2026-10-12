import Foundation
import Testing
@testable import Relay

@Test func rPausedRejectionIsActionableAndDoesNotSuggestAutomaticResume() {
    let message = RExecutionAdmission.Rejection.paused.localizedDescription
    #expect(message.contains("r_paused"))
    #expect(message.contains("No code was submitted"))
    #expect(message.contains("explicit user direction"))
    #expect(message.contains("do not retry or reauthorize"))
    #expect(message.contains("relay_r_session_status"))
}

@Test func humanConsoleRecordsDoNotClaimCompletionOrPermitAgentBypass() throws {
    let target = RExecutionTarget(paneID: UUID(), host: "host", projectRoot: "/project", sessionID: "R", connectionGeneration: UUID())
    var policy = RExecutionAdmission()
    try policy.authorize(.init(id: UUID(), target: target, actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(60)), maximumRuns: 256))
    let request = RExecutionAdmission.Request(id: UUID(), actor: "human_ui", target: target, code: "print(42)")
    try policy.recordHumanConsoleDispatch(request)
    #expect(policy.paused)
    #expect(policy.active == nil)
    #expect(policy.receipts[request.id]?.status == .unknown)
    #expect(throws: (any Error).self) { try policy.recordHumanConsoleDispatch(request) }
    let agent = RExecutionAdmission.Request(id: UUID(), actor: "authenticated_relay_mcp", target: target, code: "print(43)")
    #expect(throws: (any Error).self) { try policy.recordHumanConsoleDispatch(agent) }
    #expect(throws: (any Error).self) { try policy.admit(agent, mode: .execute, ownership: .automation) }
}

@Test func rHumanExecutionAfterTakeoverKeepsAgentsPausedAndSerializes() throws {
    let target = RExecutionTarget(paneID: UUID(), host: "host", projectRoot: "/project", sessionID: "R", connectionGeneration: UUID())
    var policy = RExecutionAdmission()
    try policy.authorize(.init(id: UUID(), target: target, actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(60)), maximumRuns: 256))
    policy.pause()
    let human = RExecutionAdmission.Request(id: UUID(), actor: "human_ui", target: target, code: "print(42)")
    _ = try policy.admit(human, mode: .execute, ownership: .human)
    try policy.begin(human.id, target: target, mode: .execute, ownership: .human)
    #expect(policy.paused)
    let second = RExecutionAdmission.Request(id: UUID(), actor: "human_ui", target: target, code: "print(43)")
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(second, mode: .execute, ownership: .human) }
    try policy.finish(human.id, status: .completed)
    #expect(policy.paused)
    let agent = RExecutionAdmission.Request(id: UUID(), actor: "authenticated_relay_mcp", target: target, code: "print(44)")
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(agent, mode: .execute, ownership: .automation) }
}

@Test("Linked R authorization survives restart with pause and unresolved ownership intact")
func rLinkedAuthorizationRestoration() throws {
    let target = RExecutionTarget(paneID: UUID(), host: "dandy-07", projectRoot: "/tmp/test", sessionID: "r-live", connectionGeneration: UUID())
    var original = RExecutionAdmission()
    try original.authorize(.init(id: UUID(), target: target, actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(60)), maximumRuns: 256))
    let request = RExecutionAdmission.Request(id: UUID(), actor: "authenticated_relay_mcp", target: target, code: "print(42)")
    _ = try original.admit(request, mode: .execute, ownership: .automation)
    try original.begin(request.id, target: target, mode: .execute, ownership: .automation)
    original.pause()
    let encoded = try JSONEncoder().encode(try #require(original.snapshot))
    let saved = try JSONDecoder().decode(RExecutionAdmission.Snapshot.self, from: encoded)
    var restored = RExecutionAdmission(restoring: saved)
    #expect(restored.paused)
    #expect(restored.active == request.id)
    #expect(restored.receipts[request.id]?.status == .unknown)
    #expect(throws: RExecutionAdmission.Rejection.self) {
        try restored.authorize(.init(id: UUID(), target: target, actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(60)), maximumRuns: 256))
    }
    try restored.reconcile(request.id, status: .completed)
    #expect(restored.active == nil)
    #expect(try restored.admit(request, mode: .execute, ownership: .automation).status == .completed)
}

@Test("Restored linked R grant admits only its original session")
func rLinkedAuthorizationIdentity() throws {
    let target = RExecutionTarget(paneID: UUID(), host: "dandy-07", projectRoot: "/tmp/test", sessionID: "r-live", connectionGeneration: UUID())
    var original = RExecutionAdmission()
    try original.authorize(.init(id: UUID(), target: target, actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(60)), maximumRuns: 256))
    var restored = RExecutionAdmission(restoring: try #require(original.snapshot))
    var request = RExecutionAdmission.Request(id: UUID(), actor: "authenticated_relay_mcp", target: target, code: "print(42)")
    _ = try restored.admit(request, mode: .execute, ownership: .automation)
    try restored.cancelAdmission(request.id)
    let other = RExecutionTarget(paneID: target.paneID, host: target.host, projectRoot: target.projectRoot, sessionID: "another-r", connectionGeneration: target.connectionGeneration)
    request = .init(id: UUID(), actor: "authenticated_relay_mcp", target: other, code: "print(42)")
    #expect(throws: RExecutionAdmission.Rejection.self) { try restored.admit(request, mode: .execute, ownership: .automation) }
}

@Test("R admission bounds authorization and serializes actors")
func rAdmissionAuthorization() throws {
    let now = ContinuousClock.now
    let target = RExecutionTarget(paneID: UUID(), host: "dandy-07", projectRoot: "/tmp/test", sessionID: "r-1", connectionGeneration: UUID())
    let grant = RExecutionGrant(id: UUID(), target: target, actors: ["codex", "claude"], expiresAt: now.advanced(by: .seconds(60)), maximumRuns: 2)
    var policy = RExecutionAdmission()
    try policy.authorize(grant)
    let first = RExecutionAdmission.Request(id: UUID(), actor: "codex", target: target, code: "plot(1)")
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(first, mode: .plan, ownership: .automation, now: now) }
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(first, mode: .execute, ownership: .human, now: now) }
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(first, mode: .execute, ownership: .unknown, now: now) }
    _ = try policy.admit(first, mode: .execute, ownership: .automation, now: now)
    let second = RExecutionAdmission.Request(id: UUID(), actor: "claude", target: target, code: "print(2)")
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(second, mode: .execute, ownership: .automation, now: now) }
    try policy.begin(first.id, target: target, mode: .execute, ownership: .automation, now: now)
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.begin(first.id, target: target, mode: .execute, ownership: .automation, now: now) }
    try policy.finish(first.id, status: .unknown)
    #expect(policy.active == first.id)
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(second, mode: .execute, ownership: .automation, now: now) }
    try policy.reconcile(first.id, status: .completed)
    #expect(try policy.admit(first, mode: .execute, ownership: .automation, now: now).status == .completed)
    _ = try policy.admit(second, mode: .execute, ownership: .automation, now: now)
    policy.revoke()
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.begin(second.id, target: target, mode: .execute, ownership: .automation, now: now) }
    try policy.cancelAdmission(second.id)
}

@Test("R grants reject expiry, identity changes and UUID payload conflicts")
func rAdmissionIdentity() throws {
    let now = ContinuousClock.now
    let target = RExecutionTarget(paneID: UUID(), host: "local", projectRoot: "/tmp/test", sessionID: "r-1", connectionGeneration: UUID())
    var policy = RExecutionAdmission()
    try policy.authorize(.init(id: UUID(), target: target, actors: ["codex"], expiresAt: now.advanced(by: .seconds(1)), maximumRuns: 1))
    let request = RExecutionAdmission.Request(id: UUID(), actor: "codex", target: target, code: "1 + 1")
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(request, mode: .execute, ownership: .automation, now: now.advanced(by: .seconds(2))) }
    let changed = RExecutionTarget(paneID: target.paneID, host: target.host, projectRoot: target.projectRoot, sessionID: target.sessionID, connectionGeneration: UUID())
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(.init(id: UUID(), actor: "codex", target: changed, code: "1"), mode: .execute, ownership: .automation, now: now) }
    _ = try policy.admit(request, mode: .execute, ownership: .automation, now: now)
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.admit(.init(id: request.id, actor: "codex", target: target, code: "2"), mode: .execute, ownership: .automation, now: now) }
    policy.pause()
    #expect(throws: RExecutionAdmission.Rejection.self) { try policy.begin(request.id, target: target, mode: .execute, ownership: .automation, now: now) }
}
