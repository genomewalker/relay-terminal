import Foundation

struct RelayCodexPaneResumeRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let expectedSession: UUID
    let targetSession: UUID
    /// "codex" when absent, so receipts and requests written before Claude
    /// support keep their meaning. "claude" resumes the expected session itself.
    var provider: String? = nil

    var agent: String { provider ?? "codex" }
    var isAdmissible: Bool {
        agent == "codex" || agent == "claude" && expectedSession == targetSession
    }
}

/// Operator-requested same-pane resume of a Codex or Claude session. Every
/// input is fenced by the same native owner and screen proof (ordered worker
/// snapshot or live renderer) used by background terminal editing.
@MainActor final class RelayCodexPaneResume {
    static let shared = RelayCodexPaneResume()
    struct Plan: Codable {
        let owner: RelayPromptOwnerBinding
        let sessionId: String
        let directory: String
        let command: String
        let configDir: String
    }
    /// relayd writes the plan, including its owner binding, in snake_case;
    /// the binding's synthesized decoder expects the converted keys.
    nonisolated static func decodePlan(_ data: Data) -> Plan? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Plan.self, from: data)
    }
    struct Receipt: Codable {
        let paneID: UUID
        let request: RelayCodexPaneResumeRequest
        var state: String
        var detail: String
        var updatedAt: Date
        func object() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        }
    }
    private var active: [UUID: Task<Void, Never>] = [:]
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Relay/AgentOperations/CodexResume", isDirectory: true)) { self.directory = directory }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    func receipt(_ id: UUID, paneID: UUID) -> Receipt? {
        guard let data = try? Data(contentsOf: url(id)), var value = try? JSONDecoder().decode(Receipt.self, from: data),
              value.paneID == paneID else { return nil }
        if active[id] == nil && ["checking", "exiting", "launching", "verifying"].contains(value.state) {
            value.state = "interrupted_outcome_unknown"
            value.detail = "The original operation is no longer running. Inspect this pane; do not replay it."
        }
        return value
    }
    private func write(_ receipt: Receipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipt).write(to: url(receipt.request.requestID), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(receipt.request.requestID).path)
    }
    func start(_ request: RelayCodexPaneResumeRequest, pane: PaneModel, workspace: WorkspaceModel,
               authorized: @escaping @MainActor () -> Bool) throws -> Receipt {
        if FileManager.default.fileExists(atPath: url(request.requestID).path) {
            guard let prior = receipt(request.requestID, paneID: pane.id), prior.request == request else {
                throw NSError(domain: "RelayCodexResume", code: 409, userInfo: [NSLocalizedDescriptionKey: "Conflicting or unreadable resume request ID"])
            }
            return prior
        }
        guard request.isAdmissible, active.isEmpty, authorized(), pane.profile.backend == .relay, pane.connectionState == .connected,
              pane.contentKind == .terminal else {
            throw NSError(domain: "RelayCodexResume", code: 409, userInfo: [NSLocalizedDescriptionKey: "Resume target or authorization unavailable"])
        }
        let initial = Receipt(paneID: pane.id, request: request, state: "checking", detail: "Checking exact native owner and saved session", updatedAt: Date())
        try write(initial)
        active[request.requestID] = Task { [weak self, weak pane, weak workspace] in
            guard let self, let pane, let workspace else { return }
            await self.run(initial, pane: pane, workspace: workspace, authorized: authorized)
            self.active[request.requestID] = nil
        }
        return initial
    }
    private func run(_ initial: Receipt, pane: PaneModel, workspace: WorkspaceModel,
                     authorized: @escaping @MainActor () -> Bool) async {
        var result = initial
        let profile = pane.profile
        var inputSent = false
        var protectedInputRevision = pane.agentInputRevision
        func current() -> Bool { authorized() && workspace.panes[pane.id] === pane && pane.profile == profile && pane.connectionState == .connected && pane.agentInputRevision == protectedInputRevision }
        // Every receipt after a line clear says so: that input reached the shell.
        var clearNote = ""
        func save(_ state: String, _ detail: String) throws {
            result.state = state; result.detail = detail + clearNote; result.updatedAt = Date(); try write(result)
        }
        do {
            let request = result.request, agent = request.agent, name = agent == "claude" ? "Claude" : "Codex"
            let command = RelayHostExecution.daemonCommand(profile: profile, arguments: Self.planArguments(pane: pane.id, provider: agent,
                expected: request.expectedSession.uuidString.lowercased(), target: request.targetSession.uuidString.lowercased()))
            let captured = try await RelayHostExecution.capture(profile: profile, command: command, timeout: 15, maximumBytes: 16_384)
            // Each refusal names the fence that held, so an operator or Miko
            // can decide without re-deriving it; none of them sends input.
            func refuse(_ reason: String) throws { try save("refused", "Refused before any input: " + reason) }
            guard current() else { try refuse("the pane, its connection or the authorization changed"); return }
            guard captured.exitCode == 0 else {
                try refuse("the host's \(name) resume plan was refused: " + String(decoding: captured.stderr.prefix(500), as: UTF8.self)); return
            }
            guard let plan = Self.decodePlan(captured.stdout) else { try refuse("the host's resume plan could not be read"); return }
            guard request.isAdmissible, plan.owner.provider == agent, plan.owner.paneId == pane.id.uuidString.lowercased(),
                  plan.owner.sessionId == request.expectedSession.uuidString.lowercased(),
                  plan.sessionId == request.targetSession.uuidString.lowercased() else {
                try refuse("the host's plan names a different provider, pane or session"); return
            }
            guard let proof = await pane.runtime.agentResumePromptProof(expected: plan.owner) else {
                try refuse("no verified idle empty \(name) prompt (busy, draft, approval, background work, or the screen or owner changed)"); return
            }
            guard current() else { try refuse("the pane, its connection or the authorization changed"); return }
            try save("exiting", "Graceful \(name) exit requested for the verified original session")
            let (exit, submit) = Self.exitEdit(provider: agent, instance: request.instance, requestID: request.requestID, token: proof)
            guard await pane.runtime.sendTerminalEdit(exit, appendShellReturn: submit, authorization: current) == "input_submitted" else {
                try save("not_sent", "The original owner or screen changed; no exit input was submitted"); return
            }
            inputSent = true
            protectedInputRevision = pane.agentInputRevision
            // The kernel owner can become the shell before its prompt is on
            // screen (the agent's restored main screen still shows the old
            // launch line, or exit text is in flight), so the empty proof is
            // retried under the same owner until the deadline. A line that
            // stays typed is cleared at most with Ctrl-U then Ctrl-K, each
            // under its own fenced shell proof, and must then prove empty.
            var shell: RelayPromptOwnerBinding?, token: UUID?
            var typedPolls = 0, clearsSent = 0
            var reason = "no shell owner was observed before the deadline"
            let deadline = Date().addingTimeInterval(30)
            while current(), Date() < deadline {
                if let owner = await pane.runtime.agentResumeOwner(), owner.provider == "shell" {
                    guard Self.sameRetainedShell(plan.owner, owner) else { reason = "a different shell owns the pane"; break }
                    shell = owner
                    if let proof = await pane.runtime.agentResumePromptProof(expected: owner), current() { token = proof; break }
                    guard current() else { reason = "a fence changed while the shell prompt was checked"; break }
                    if let proof = await pane.runtime.agentResumePromptProof(expected: owner, admitTypedShell: true), current() {
                        typedPolls += 1
                        reason = clearsSent == 0 ? "the shell input line was not empty" : "the shell input line was still not empty after clearing"
                        if let key = Self.shellClearKey(typedPolls: typedPolls, clearsSent: clearsSent) {
                            let clear = RelayTerminalEditRequest(instance: request.instance, requestID: UUID(), token: proof,
                                action: "key", text: nil, key: key, modifiers: ["control"])
                            // not_sent submits nothing: the prompt may just have
                            // been redrawn, so poll again instead of holding.
                            if await pane.runtime.sendTerminalEdit(clear, authorization: current) == "input_submitted" {
                                clearsSent += 1
                                clearNote = clearsSent == 1 ? " (Control-U cleared the shell line first)" : " (Control-U and Control-K cleared the shell line first)"
                                protectedInputRevision = pane.agentInputRevision
                            }
                            typedPolls = 0
                        }
                    } else {
                        typedPolls = 0
                        reason = "the retained shell prompt was not recognized"
                    }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            if !current() { reason = "the pane, its connection, authorization or input revision changed" }
            guard current(), let shell, let token else {
                try save("held", "Exit submitted; the same retained empty shell was not verified (\(reason)). No resume was sent."); return
            }
            try save("launching", "Launching the exact saved session in its original account and project")
            let launch = RelayTerminalEditRequest(instance: request.instance, requestID: UUID(), token: token, action: "insert_text", text: plan.command, key: nil, modifiers: nil)
            guard await pane.runtime.sendTerminalEdit(launch, appendShellReturn: true, authorization: current) == "input_submitted" else {
                try save("held", "The retained shell changed before the launch text was submitted"); return
            }
            protectedInputRevision = pane.agentInputRevision
            try save("verifying", "Resume submitted once; checking the resulting native session")
            let verifyUntil = Date().addingTimeInterval(90)
            while current(), Date() < verifyUntil {
                if let owner = await pane.runtime.agentResumeOwner(), Self.verified(plan.owner, after: owner, target: request.targetSession) {
                    let verifyCommand = RelayHostExecution.daemonCommand(profile: profile, arguments: Self.planArguments(pane: pane.id, provider: agent, expected: plan.sessionId, target: plan.sessionId))
                    let account = try await RelayHostExecution.capture(profile: profile, command: verifyCommand, timeout: 15, maximumBytes: 16_384)
                    guard current(), account.exitCode == 0,
                          let verified = Self.decodePlan(account.stdout),
                          verified.owner == owner, verified.configDir == plan.configDir else {
                        try save("outcome_unknown", "The requested session is bound but its original account was not reverified. Do not replay."); return
                    }
                    try save("verified", "Exact saved \(name) session resumed; pane, account, worker and shell preserved"); return
                }
                try await Task.sleep(for: .seconds(1))
            }
            try save("outcome_unknown", "Resume was submitted once; the expected native binding was not confirmed. Inspect; do not replay.")
        } catch {
            try? save(inputSent ? "outcome_unknown" : "refused", error.localizedDescription)
        }
    }
    /// The next line-clearing control key for a retained shell whose recognized
    /// prompt has shown typed text on two consecutive fenced polls: Ctrl-U kills
    /// to the line start, then Ctrl-K kills what was after the cursor. Never
    /// more than these two; an agent owner is never admitted for either.
    nonisolated static func shellClearKey(typedPolls: Int, clearsSent: Int) -> String? {
        guard typedPolls >= 2, clearsSent < 2 else { return nil }
        return clearsSent == 0 ? "u" : "k"
    }
    static func sameRetainedShell(_ before: RelayPromptOwnerBinding, _ after: RelayPromptOwnerBinding) -> Bool {
        before.paneId == after.paneId && before.nodeBootId == after.nodeBootId && before.workerPid == after.workerPid && before.workerStart == after.workerStart && before.shellPid == after.shellPid && before.shellStart == after.shellStart
    }
    /// The relayd plan for one provider. Claude resumes the expected session itself.
    static func planArguments(pane: UUID, provider: String, expected: String, target: String) -> [String] {
        provider == "claude" ? ["claude-pane-resume-plan", pane.uuidString.lowercased(), expected]
            : ["codex-pane-resume-plan", pane.uuidString.lowercased(), expected, target]
    }
    /// The provider's graceful exit: Codex's Control-D, or Claude's fixed /exit
    /// command submitted with Return (the only agent text that may carry one).
    static func exitEdit(provider: String, instance: UUID, requestID: UUID, token: UUID) -> (RelayTerminalEditRequest, submit: Bool) {
        if provider == "claude" {
            return (.init(instance: instance, requestID: requestID, token: token, action: "insert_text",
                          text: RelayAgentMaintenancePolicy.exitCommand(provider: "claude"), key: nil, modifiers: nil), true)
        }
        return (.init(instance: instance, requestID: requestID, token: token, action: "key", text: nil, key: "d", modifiers: ["control"]), false)
    }
    /// `before` is the admitted plan owner, whose provider equals the request's.
    static func verified(_ before: RelayPromptOwnerBinding, after: RelayPromptOwnerBinding, target: UUID) -> Bool {
        sameRetainedShell(before, after) && ["codex", "claude"].contains(before.provider) && after.provider == before.provider && after.inputOnly != true && after.sessionId == target.uuidString.lowercased() && (before.processId != after.processId || before.processStart != after.processStart)
    }
}
