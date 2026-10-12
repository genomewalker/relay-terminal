import Foundation
import Testing
@testable import Relay

private func supervisorTelemetry(
    _ identity: RelaySupervisedSessionID,
    at date: Date,
    reachable: Bool = true,
    retries: Int = 0,
    output: Int = 0,
    stalled: TimeInterval = 0,
    active: Bool = true,
    tokens: Int? = nil,
    limit: Int? = nil,
    restarts: Int = 0,
    checkpoint: Bool = false
) -> RelaySupervisorTelemetry {
    RelaySupervisorTelemetry(
        identity: identity, observedAt: date, hasActiveRequest: active,
        isReachable: reachable, outputBytesPerMinute: output,
        retriesInWindow: retries, secondsSinceProgress: stalled,
        contextTokens: tokens, contextLimit: limit,
        restartsInWindow: restarts, hasDurableCheckpoint: checkpoint
    )
}

@Test("Supervisor escalates one rung at a time and never executes automatically")
func supervisorEscalatesOneRungAtATime() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "codex-a", generation: 7)
    let start = Date(timeIntervalSince1970: 1_000)
    var supervisor = RelaySessionSupervisor(configuration: .init(escalationCooldown: 0))
    let sample = supervisorTelemetry(id, at: start, retries: 50, output: 200 * 1_024 * 1_024, checkpoint: true)

    let first = supervisor.evaluate(sample)
    #expect(first.stage == .warn)
    #expect(!first.mayExecuteAutomatically)
    let second = supervisor.evaluate(supervisorTelemetry(id, at: start.addingTimeInterval(1), retries: 50, checkpoint: true))
    #expect(second.stage == .stopNewWork)
    #expect(second.requiresUserApproval)
}

@Test("An unreachable remote can warn but cannot escalate into remote mutation")
func unreachableFailsClosed() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "remote", generation: 2)
    var supervisor = RelaySessionSupervisor(configuration: .init(escalationCooldown: 0))
    for offset in 0..<8 {
        let result = supervisor.evaluate(supervisorTelemetry(
            id, at: Date(timeIntervalSince1970: TimeInterval(offset)), reachable: false,
            retries: 100, output: 500 * 1_024 * 1_024, restarts: 20, checkpoint: true
        ))
        #expect(result.stage == .warn)
        #expect(!result.mayExecuteAutomatically)
    }
}

@Test("Model suggestions cannot retarget or exceed deterministic policy")
func modelSuggestionIsBounded() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "claude", generation: 4)
    let other = RelaySupervisedSessionID(paneID: id.paneID, sessionID: "claude", generation: 5)
    var supervisor = RelaySessionSupervisor(configuration: .init(escalationCooldown: 0))
    let result = supervisor.evaluate(supervisorTelemetry(id, at: Date(), retries: 6))

    #expect(supervisor.boundedModelSuggestion(.observe, for: result, identity: id) == .observe)
    #expect(supervisor.boundedModelSuggestion(.terminateOrRestart, for: result, identity: id) == nil)
    #expect(supervisor.boundedModelSuggestion(.warn, for: result, identity: other) == nil)
}

@Test("Supervisor model advisories are identity-fenced and cannot exceed policy")
func supervisorAdvisoryPolicyIsBounded() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "codex", generation: 4)
    let replacement = RelaySupervisedSessionID(paneID: id.paneID, sessionID: id.sessionID, generation: 5)
    let recommendation = RelaySupervisorRecommendation(
        identity: id, stage: .requestCheckpoint, findings: [.stalled],
        observedAt: Date(timeIntervalSince1970: 10),
        requiresUserApproval: true, mayExecuteAutomatically: false
    )

    #expect(RelaySupervisorAdvisoryPolicy.validate(
        suggestedStage: .gracefulInterrupt, summary: "Too severe",
        source: .appleFoundationModels, recommendation: recommendation,
        currentIdentity: id
    ) == nil)
    #expect(RelaySupervisorAdvisoryPolicy.validate(
        suggestedStage: .warn, summary: "Stalled\n  output needs review.",
        source: .appleFoundationModels, recommendation: recommendation,
        currentIdentity: replacement
    ) == nil)

    let accepted = RelaySupervisorAdvisoryPolicy.validate(
        suggestedStage: .warn, summary: "Stalled\n  output needs review.",
        source: .appleFoundationModels, recommendation: recommendation,
        currentIdentity: id
    )
    #expect(accepted?.suggestedStage == .warn)
    #expect(accepted?.summary == "Stalled output needs review.")
}

@Test("Supervisor advisory summaries are bounded and non-empty")
func supervisorAdvisorySummaryIsBounded() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "claude", generation: 1)
    let recommendation = RelaySupervisorRecommendation(
        identity: id, stage: .warn, findings: [.retryLoop], observedAt: Date(),
        requiresUserApproval: false, mayExecuteAutomatically: false
    )
    #expect(RelaySupervisorAdvisoryPolicy.validate(
        suggestedStage: .observe, summary: "   \n ", source: .appleFoundationModels,
        recommendation: recommendation, currentIdentity: id
    ) == nil)
    let accepted = RelaySupervisorAdvisoryPolicy.validate(
        suggestedStage: .warn, summary: String(repeating: "x", count: 400),
        source: .appleFoundationModels, recommendation: recommendation,
        currentIdentity: id
    )
    #expect(accepted?.summary.count == RelaySupervisorAdvisoryPolicy.maximumSummaryLength)
}

@Test("Recovery requires consecutive healthy observations")
func supervisorRecoveryIsDebounced() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "local", generation: 1)
    var config = RelaySupervisorConfiguration(escalationCooldown: 0)
    config.recoverySamples = 3
    var supervisor = RelaySessionSupervisor(configuration: config)
    _ = supervisor.evaluate(supervisorTelemetry(id, at: Date(timeIntervalSince1970: 0), retries: 9))
    #expect(supervisor.evaluate(supervisorTelemetry(id, at: Date(timeIntervalSince1970: 1), active: false)).stage == .warn)
    #expect(supervisor.evaluate(supervisorTelemetry(id, at: Date(timeIntervalSince1970: 2), active: false)).stage == .warn)
    #expect(supervisor.evaluate(supervisorTelemetry(id, at: Date(timeIntervalSince1970: 3), active: false)).stage == .observe)
}

@MainActor
@Test("Pane telemetry is bounded, generation-fenced and workspace-visible")
func paneTelemetryFeedsWorkspaceSupervisor() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = try! #require(workspace.activePane)
    pane.received("OpenAI Codex CLI\nworking\n")
    let now = Date()

    let first = pane.supervisorTelemetry(now: now)
    #expect(first.identity.paneID == pane.id)
    #expect(first.outputBytesPerMinute > 0)
    #expect(first.isReachable)

    pane.connectionState = .reconnecting("test reconnect")
    let second = pane.supervisorTelemetry(now: now.addingTimeInterval(1))
    #expect(second.identity.generation > first.identity.generation)
    #expect(!second.isReachable)
    #expect(second.restartsInWindow == 1)

    workspace.refreshSupervisorRecommendations(now: now.addingTimeInterval(1))
    let recommendation = try! #require(workspace.supervisorRecommendations[pane.id])
    #expect(recommendation.identity == second.identity)
    #expect(recommendation.findings.contains(.unreachable))
    #expect(!recommendation.mayExecuteAutomatically)
    workspace.shutdown()
}

@Test("Lifecycle receipts require approval and reject stale identities")
func supervisorReceiptsAreFenced() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "codex", generation: 8)
    let recommendation = RelaySupervisorRecommendation(
        identity: id, stage: .stopNewWork, findings: [.retryLoop],
        observedAt: Date(timeIntervalSince1970: 10),
        requiresUserApproval: true, mayExecuteAutomatically: false
    )
    var broker = RelaySupervisorActionBroker()
    let proposed = broker.propose(recommendation, now: recommendation.observedAt)
    let proposal = try! #require(proposed)
    #expect(proposal.state == .proposed)

    let replacement = RelaySupervisedSessionID(
        paneID: id.paneID, sessionID: id.sessionID, generation: id.generation + 1
    )
    let resolved = broker.resolve(
        proposal.id, approve: true, currentIdentity: replacement,
        now: recommendation.observedAt.addingTimeInterval(1)
    )
    let stale = try! #require(resolved)
    #expect(stale.state == .staleIdentity)
    #expect(broker.resolve(proposal.id, approve: true, currentIdentity: id) == nil)
}

@Test("Observations and warnings cannot create lifecycle receipts")
func warningsCannotCreateReceipts() {
    let id = RelaySupervisedSessionID(paneID: UUID(), sessionID: "claude", generation: 1)
    var broker = RelaySupervisorActionBroker()
    let warning = RelaySupervisorRecommendation(
        identity: id, stage: .warn, findings: [.stalled], observedAt: Date(),
        requiresUserApproval: false, mayExecuteAutomatically: false
    )
    #expect(broker.propose(warning) == nil)
}

@Test("Approved supervisor actions are capability checked and consumed once")
func supervisorExecutorClaimsOnce() {
    let now = Date(timeIntervalSince1970: 100)
    let identity = RelaySupervisedSessionID(paneID: UUID(), sessionID: "codex", generation: 3)
    let receipt = RelaySupervisorActionReceipt(
        id: UUID(), identity: identity, stage: .gracefulInterrupt,
        createdAt: now, expiresAt: now.addingTimeInterval(60),
        resolvedAt: now, state: .approved
    )
    var executor = RelaySupervisorActionExecutor()
    let first = executor.claim(
        receipt, currentIdentity: identity, isReachable: true,
        capabilities: [.gracefulInterrupt], now: now
    )
    let claim = try! first.get()
    #expect(claim.command == .gracefulInterrupt)
    let second = executor.claim(
        receipt, currentIdentity: identity, isReachable: true,
        capabilities: [.gracefulInterrupt], now: now
    )
    #expect(second == .failure(.alreadyConsumed))
}

@Test("Offline supervisor approval fails closed and cannot be replayed")
func supervisorExecutorRejectsOfflineReplay() {
    let now = Date(timeIntervalSince1970: 200)
    let identity = RelaySupervisedSessionID(paneID: UUID(), sessionID: "claude", generation: 9)
    let receipt = RelaySupervisorActionReceipt(
        id: UUID(), identity: identity, stage: .gracefulInterrupt,
        createdAt: now, expiresAt: now.addingTimeInterval(60),
        resolvedAt: now, state: .approved
    )
    var executor = RelaySupervisorActionExecutor()
    #expect(executor.claim(
        receipt, currentIdentity: identity, isReachable: false,
        capabilities: [.gracefulInterrupt], now: now
    ) == .failure(.unreachable))
    #expect(executor.claim(
        receipt, currentIdentity: identity, isReachable: true,
        capabilities: [.gracefulInterrupt], now: now
    ) == .failure(.alreadyConsumed))
}

@Test("Supervisor executor rejects stale identities and unsupported stages")
func supervisorExecutorRejectsStaleAndUnsupportedActions() {
    let now = Date(timeIntervalSince1970: 300)
    let identity = RelaySupervisedSessionID(paneID: UUID(), sessionID: "codex", generation: 2)
    let stale = RelaySupervisedSessionID(paneID: identity.paneID, sessionID: identity.sessionID, generation: 3)
    func receipt(_ stage: RelaySupervisorStage) -> RelaySupervisorActionReceipt {
        RelaySupervisorActionReceipt(
            id: UUID(), identity: identity, stage: stage,
            createdAt: now, expiresAt: now.addingTimeInterval(60),
            resolvedAt: now, state: .approved
        )
    }
    var executor = RelaySupervisorActionExecutor()
    #expect(executor.claim(
        receipt(.gracefulInterrupt), currentIdentity: stale, isReachable: true,
        capabilities: [.gracefulInterrupt], now: now
    ) == .failure(.staleIdentity))
    #expect(executor.claim(
        receipt(.terminateOrRestart), currentIdentity: identity, isReachable: true,
        capabilities: [.gracefulInterrupt], now: now
    ) == .failure(.unsupportedStage))
    #expect(executor.claim(
        receipt(.gracefulInterrupt), currentIdentity: identity, isReachable: true,
        capabilities: [], now: now
    ) == .failure(.missingCapability))
}


private extension RelaySupervisorConfiguration {
    init(escalationCooldown: TimeInterval) {
        self.init()
        self.escalationCooldown = escalationCooldown
    }
}
