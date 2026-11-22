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
        /// Set for a refused or held outcome: why, and what clears it.
        var reasonCode: String? = nil
        var blocker: String? = nil
        var howToClear: String? = nil
        /// The admitted host plan, kept once the exit is about to be sent, so a
        /// pane held after its exit can be relaunched in the same account. It is
        /// stored as relayd's own plan JSON: the owner binding encodes its wire
        /// (snake_case) keys, which only `decodePlan` reads back.
        var planJSON: String? = nil
        var plan: Plan? {
            get { planJSON.flatMap { RelayCodexPaneResume.decodePlan(Data($0.utf8)) } }
            set { planJSON = newValue.flatMap { try? JSONEncoder().encode(Self.WirePlan($0)) }.map { String(decoding: $0, as: UTF8.self) } }
        }
        /// Plan in relayd's snake_case layout.
        private struct WirePlan: Encodable {
            let owner: RelayPromptOwnerBinding, sessionId: String, directory: String, command: String, configDir: String
            init(_ plan: Plan) {
                owner = plan.owner; sessionId = plan.sessionId; directory = plan.directory; command = plan.command; configDir = plan.configDir
            }
            enum CodingKeys: String, CodingKey {
                case owner, sessionId = "session_id", directory, command, configDir = "config_dir"
            }
        }
        enum CodingKeys: String, CodingKey {
            case paneID, request, state, detail, updatedAt
            case planJSON = "plan"
            case reasonCode = "reason_code", blocker, howToClear = "how_to_clear"
        }
        mutating func set(_ refusal: RelayPaneOperationRefusal?) {
            reasonCode = refusal?.code.rawValue; blocker = refusal?.blocker; howToClear = refusal?.howToClear
        }
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
            value.set(.init(.exitNotVerified, value.detail))
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
                throw RelayPaneOperationRefusal(.invalidRequest, "Conflicting or unreadable resume request ID")
            }
            return prior
        }
        if let refusal = Self.startRefusal(request, busy: !active.isEmpty, authorized: authorized(), backend: pane.profile.backend,
                                           connection: pane.connectionState, content: pane.contentKind) {
            throw refusal
        }
        let candidate = recoverablePlan(pane: pane.id, request: request)
        let initial = Receipt(paneID: pane.id, request: request, state: "checking", detail: "Checking exact native owner and saved session", updatedAt: Date())
        try write(initial)
        active[request.requestID] = Task { [weak self, weak pane, weak workspace] in
            guard let self else { return }
            defer { self.active[request.requestID] = nil }
            guard let pane, let workspace, workspace.panes[pane.id] === pane else {
                var result = initial
                result.state = "refused"
                result.detail = "Refused before any input: the pane or workspace closed before the resume started"
                result.set(.init(.paneChanged, result.detail))
                result.updatedAt = Date()
                try? self.write(result)
                return
            }
            // Recovery only while the held plan's retained shell owns the
            // prompt; once an agent runs there again, the ordinary resume.
            let recovering = candidate == nil ? nil
                : Self.recoveryApplies(held: candidate, currentOwner: await pane.runtime.agentResumeOwner())
            await self.run(initial, pane: pane, workspace: workspace, authorized: authorized, recovering: recovering)
        }
        return initial
    }
    /// A Codex resume of this pane that was held after its exit was submitted
    /// (exit_not_verified), with its admitted plan for the same target session.
    /// A new request for that session relaunches it in the retained shell.
    func recoverablePlan(pane: UUID, request: RelayCodexPaneResumeRequest) -> Plan? {
        guard request.agent == "codex",
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let target = request.targetSession.uuidString.lowercased()
        let held = files.compactMap { file -> Receipt? in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(Receipt.self, from: data) else { return nil }
            return value
        }.filter { Self.recoverable($0, pane: pane, target: target) }
        return held.max { $0.updatedAt < $1.updatedAt }?.plan
    }
    /// The held plan to relaunch, only when the pane's current owner is that
    /// plan's own retained shell; nil means an ordinary resume.
    nonisolated static func recoveryApplies(held: Plan?, currentOwner: RelayPromptOwnerBinding?) -> Plan? {
        guard let held, let currentOwner, currentOwner.provider == "shell",
              sameRetainedShellValues(held.owner, currentOwner) else { return nil }
        return held
    }
    nonisolated static func recoverable(_ receipt: Receipt, pane: UUID, target: String) -> Bool {
        receipt.paneID == pane && receipt.request.agent == "codex" && receipt.state == "held" &&
            receipt.reasonCode == RelayPaneOperationRefusal.Code.exitNotVerified.rawValue &&
            receipt.plan?.sessionId == target && receipt.plan?.owner.provider == "codex"
    }
    /// The relayd relaunch plan for a recovered pane must be the same pane,
    /// retained shell, account, directory and session as the held plan.
    nonisolated static func relaunchMatches(_ relaunch: Plan, held: Plan) -> Bool {
        relaunch.owner.provider == "shell" && relaunch.owner.paneId == held.owner.paneId &&
            sameRetainedShellValues(held.owner, relaunch.owner) && relaunch.configDir == held.configDir &&
            relaunch.directory == held.directory && relaunch.sessionId == held.sessionId
    }
    nonisolated static func sameRetainedShellValues(_ before: RelayPromptOwnerBinding, _ after: RelayPromptOwnerBinding) -> Bool {
        before.paneId == after.paneId && before.nodeBootId == after.nodeBootId && before.workerPid == after.workerPid &&
            before.workerStart == after.workerStart && before.shellPid == after.shellPid && before.shellStart == after.shellStart
    }
    private func run(_ initial: Receipt, pane: PaneModel, workspace: WorkspaceModel,
                     authorized: @escaping @MainActor () -> Bool, recovering: Plan? = nil) async {
        var result = initial
        let profile = pane.profile
        var inputSent = false
        var protectedInputRevision = pane.agentInputRevision
        func current() -> Bool { authorized() && workspace.panes[pane.id] === pane && pane.profile == profile && pane.connectionState == .connected && pane.agentInputRevision == protectedInputRevision }
        // Every receipt after a line clear says so: that input reached the shell.
        var clearNote = ""
        func save(_ state: String, _ detail: String, _ code: RelayPaneOperationRefusal.Code? = nil,
                  host: RelayPaneOperationRefusal? = nil) throws {
            result.state = state; result.detail = detail + clearNote; result.updatedAt = Date()
            result.set(host.map { .init($0.code, result.detail, howToClear: $0.howToClear) } ?? code.map { .init($0, result.detail) })
            try write(result)
        }
        do {
            let request = result.request, agent = request.agent, name = agent == "claude" ? "Claude" : "Codex"
            let plan: Plan
            var shell: RelayPromptOwnerBinding?, token: UUID?
            var reason = "no shell owner was observed before the deadline"
            func refuseRecovery(_ reason: String, _ code: RelayPaneOperationRefusal.Code, host: RelayPaneOperationRefusal? = nil) throws {
                try save("refused", "Refused before any input: " + reason, code, host: host)
            }
            if let held = recovering {
                let relaunchCommand = RelayHostExecution.daemonCommand(profile: profile, arguments: ["codex-pane-relaunch-plan",
                    pane.id.uuidString.lowercased(), held.sessionId, held.configDir])
                let captured = try await RelayHostExecution.capture(profile: profile, command: relaunchCommand, timeout: 15, maximumBytes: 16_384)
                guard current() else { try refuseRecovery("the pane, its connection or the authorization changed", .paneChanged); return }
                guard captured.exitCode == 0 else {
                    try refuseRecovery("the host's Codex relaunch plan was refused: " + String(decoding: captured.stderr.prefix(500), as: UTF8.self),
                                       .unclassified, host: RelayPaneOperationRefusal.hostRefusal(stderr: captured.stderr)); return
                }
                guard let relaunch = Self.decodePlan(captured.stdout), Self.relaunchMatches(relaunch, held: held) else {
                    try refuseRecovery("the host's relaunch plan names a different shell, account, directory or session", .paneChanged); return
                }
                guard let proof = await pane.runtime.agentResumePromptProof(expected: relaunch.owner), current() else {
                    try refuseRecovery("the retained shell's prompt is not verified empty", .promptUnverified); return
                }
                plan = held
                shell = relaunch.owner
                token = proof
                result.plan = held
            } else {
            let command = RelayHostExecution.daemonCommand(profile: profile, arguments: Self.planArguments(pane: pane.id, provider: agent,
                expected: request.expectedSession.uuidString.lowercased(), target: request.targetSession.uuidString.lowercased()))
            let captured = try await RelayHostExecution.capture(profile: profile, command: command, timeout: 15, maximumBytes: 16_384)
            // Each refusal names the fence that held, so an operator or Miko
            // can decide without re-deriving it; none of them sends input.
            func refuse(_ reason: String, _ code: RelayPaneOperationRefusal.Code, host: RelayPaneOperationRefusal? = nil) throws {
                try save("refused", "Refused before any input: " + reason, code, host: host)
            }
            guard current() else { try refuse("the pane, its connection or the authorization changed", .paneChanged); return }
            guard captured.exitCode == 0 else {
                try refuse("the host's \(name) resume plan was refused: " + String(decoding: captured.stderr.prefix(500), as: UTF8.self),
                           .unclassified, host: RelayPaneOperationRefusal.hostRefusal(stderr: captured.stderr)); return
            }
            guard let admitted = Self.decodePlan(captured.stdout) else { try refuse("the host's resume plan could not be read", .hostUnreachable); return }
            plan = admitted
            guard request.isAdmissible, plan.owner.provider == agent, plan.owner.paneId == pane.id.uuidString.lowercased() else {
                try refuse("the host's plan names a different provider or pane", .paneChanged); return
            }
            if let mismatch = Self.sessionRefusal(request, plan: plan) { try refuse(mismatch.blocker, mismatch.code); return }
            // An agent the worker started without a shell (its shell pid is the
            // agent itself) leaves no prompt to resume in once it exits: pane
            // 48005fe5 on dandy-07, 2026-11-22, ended with no agent and no shell.
            if Self.agentIsItsOwnShell(plan.owner) {
                try refuse("the agent runs without a shell under the pane worker; exiting it would leave no shell to resume the session in", .resumeUnavailable); return
            }
            let checked = await pane.runtime.agentResumePromptCheck(expected: plan.owner)
            guard let proof = checked.token else {
                let why = checked.refusal ?? .init(.promptUnverified, "the screen or owner changed")
                try refuse("no verified idle empty \(name) prompt: " + why.blocker, why.code); return
            }
            guard current() else { try refuse("the pane, its connection or the authorization changed", .paneChanged); return }
            result.plan = admitted
            try save("exiting", "Graceful \(name) exit requested for the verified original session")
            let (exit, submit) = Self.exitEdit(provider: agent, instance: request.instance, requestID: request.requestID, token: proof)
            let exitReceipt = await pane.runtime.sendTerminalEditReceipt(exit, appendShellReturn: submit, authorization: current)
            guard exitReceipt.status == "input_submitted", let exitRevision = exitReceipt.inputRevision else {
                try save("not_sent", "The original owner or screen changed; no exit input was submitted", .paneChanged); return
            }
            inputSent = true
            protectedInputRevision = exitRevision
            // The kernel owner can become the shell before its prompt is on
            // screen (the agent's restored main screen still shows the old
            // launch line, or exit text is in flight), so the empty proof is
            // retried under the same owner until the deadline. A line that
            // stays typed is cleared at most with Ctrl-U then Ctrl-K, each
            // under its own fenced shell proof, and must then prove empty.
            var typedPolls = 0, clearsSent = 0
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
                            let clearReceipt = await pane.runtime.sendTerminalEditReceipt(clear, authorization: current)
                            if clearReceipt.status == "input_submitted", let clearRevision = clearReceipt.inputRevision {
                                clearsSent += 1
                                clearNote = clearsSent == 1 ? " (Control-U cleared the shell line first)" : " (Control-U and Control-K cleared the shell line first)"
                                protectedInputRevision = clearRevision
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
            }
            guard current(), let shell, let token else {
                try save("held", "Exit submitted; the same retained empty shell was not verified (\(reason)). No resume was sent.", .exitNotVerified); return
            }
            _ = shell
            try save("launching", recovering == nil ? "Launching the exact saved session in its original account and project"
                : "Relaunching the exact saved session in the retained shell, in its original account and project")
            let launch = RelayTerminalEditRequest(instance: request.instance, requestID: UUID(), token: token, action: "insert_text", text: plan.command, key: nil, modifiers: nil)
            let launchReceipt = await pane.runtime.sendTerminalEditReceipt(launch, appendShellReturn: true, authorization: current)
            guard launchReceipt.status == "input_submitted", let launchRevision = launchReceipt.inputRevision else {
                try save("held", "The retained shell changed before the launch text was submitted", .exitNotVerified); return
            }
            inputSent = true
            protectedInputRevision = launchRevision
            try save("verifying", "Resume submitted once; checking the resulting native session")
            let verifyUntil = Date().addingTimeInterval(90)
            while current(), Date() < verifyUntil {
                if agent == "codex", RelayAgentMaintenancePrompt.isCodexFolderTrustDialog(pane.runtime.sidePanelViewportText()) {
                    try save("held", "Resume launched once; Codex stopped at its folder-trust dialog for " + plan.directory +
                             ". Relay did not answer it.", .trustPrompt); return
                }
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
            try? save(inputSent ? "outcome_unknown" : "refused", error.localizedDescription, inputSent ? nil : .hostUnreachable)
        }
    }
    /// Why a resume request cannot start, before any receipt is written: each
    /// condition has its own code instead of one opaque refusal.
    nonisolated static func startRefusal(_ request: RelayCodexPaneResumeRequest, busy: Bool, authorized: Bool,
                                         backend: RemoteSessionBackend, connection: PaneConnectionState,
                                         content: PaneContentKind) -> RelayPaneOperationRefusal? {
        if !request.isAdmissible {
            return .init(.invalidRequest, "A Claude resume restarts the pane's own session; target_session must equal expected_session")
        }
        if busy { return .init(.operationInProgress, "Another same-pane resume is running") }
        if !authorized { return .init(.authorizationGrant, "The terminal input grant or this caller's access is not current") }
        if backend != .relay { return .init(.unsupportedPane, "The pane is not on a Relay-managed backend") }
        if connection != .connected { return .init(.paneNotConnected, "The pane is not connected") }
        if content != .terminal { return .init(.unsupportedPane, "The pane is not a terminal") }
        return nil
    }
    /// The request's sessions against the host plan: the pane is bound to
    /// another session than expected_session, or the plan resumes another.
    nonisolated static func sessionRefusal(_ request: RelayCodexPaneResumeRequest, plan: Plan) -> RelayPaneOperationRefusal? {
        let expected = request.expectedSession.uuidString.lowercased(), target = request.targetSession.uuidString.lowercased()
        if plan.owner.sessionId != expected {
            return .init(.targetSession, "the pane is bound to session " + (plan.owner.sessionId ?? "none") + ", not expected_session " + expected)
        }
        if plan.sessionId != target {
            return .init(.targetSession, "the host plans session " + plan.sessionId + ", not target_session " + target)
        }
        return nil
    }
    /// The next line-clearing control key for a retained shell whose recognized
    /// prompt has shown typed text on two consecutive fenced polls: Ctrl-U kills
    /// to the line start, then Ctrl-K kills what was after the cursor. Never
    /// more than these two; an agent owner is never admitted for either.
    nonisolated static func shellClearKey(typedPolls: Int, clearsSent: Int) -> String? {
        guard typedPolls >= 2, clearsSent < 2 else { return nil }
        return clearsSent == 0 ? "u" : "k"
    }
    /// The worker started the agent directly: the owner's shell is the agent
    /// process itself, so nothing remains at a prompt after it exits.
    nonisolated static func agentIsItsOwnShell(_ owner: RelayPromptOwnerBinding) -> Bool {
        owner.provider != "shell" && owner.shellPid == owner.processId && owner.shellStart == owner.processStart
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
