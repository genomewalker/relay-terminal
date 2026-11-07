import Foundation

struct RelayCodexPaneResumeRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let expectedSession: UUID
    let targetSession: UUID
}

/// Operator-requested recovery. Every input is fenced by the same native
/// owner and ordered screen proof used by background terminal editing.
@MainActor final class RelayCodexPaneResume {
    static let shared = RelayCodexPaneResume()
    struct Plan: Codable {
        let owner: RelayPromptOwnerBinding
        let session_id: String
        let directory: String
        let command: String
        let config_dir: String
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
        guard active.isEmpty, authorized(), pane.profile.backend == .relay, pane.connectionState == .connected,
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
        func save(_ state: String, _ detail: String) throws {
            result.state = state; result.detail = detail; result.updatedAt = Date(); try write(result)
        }
        do {
            let request = result.request
            let command = RelayHostExecution.daemonCommand(profile: profile, arguments: ["codex-pane-resume-plan", pane.id.uuidString.lowercased(), request.expectedSession.uuidString.lowercased(), request.targetSession.uuidString.lowercased()])
            let captured = try await RelayHostExecution.capture(profile: profile, command: command, timeout: 15, maximumBytes: 16_384)
            guard current(), captured.exitCode == 0,
                  let plan = try? JSONDecoder().decode(Plan.self, from: captured.stdout),
                  plan.owner.provider == "codex", plan.owner.paneId == pane.id.uuidString.lowercased(),
                  plan.owner.sessionId == request.expectedSession.uuidString.lowercased(),
                  plan.session_id == request.targetSession.uuidString.lowercased(),
                  let proof = await pane.runtime.agentResumePromptProof(expected: plan.owner), current() else {
                try save("refused", "No verified idle empty Codex prompt or exact saved-session plan. " + String(decoding: captured.stderr.prefix(500), as: UTF8.self)); return
            }
            try save("exiting", "Graceful Codex exit requested for the verified original session")
            let exit = RelayTerminalEditRequest(instance: request.instance, requestID: request.requestID, token: proof, action: "key", text: nil, key: "d", modifiers: ["control"])
            guard await pane.runtime.sendTerminalEdit(exit, authorization: current) == "input_submitted" else {
                try save("not_sent", "The original owner or screen changed; no exit input was submitted"); return
            }
            inputSent = true
            protectedInputRevision = pane.agentInputRevision
            var shell: RelayPromptOwnerBinding?
            let deadline = Date().addingTimeInterval(30)
            while current(), Date() < deadline {
                if let owner = await pane.runtime.agentResumeOwner(), owner.provider == "shell" {
                    guard Self.sameRetainedShell(plan.owner, owner) else { break }
                    shell = owner; break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard current(), let shell, let token = await pane.runtime.agentResumePromptProof(expected: shell), current() else {
                try save("held", "Exit submitted; the same retained empty shell was not verified. No resume was sent."); return
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
                    let verifyCommand = RelayHostExecution.daemonCommand(profile: profile, arguments: ["codex-pane-resume-plan", pane.id.uuidString.lowercased(), plan.session_id, plan.session_id])
                    let account = try await RelayHostExecution.capture(profile: profile, command: verifyCommand, timeout: 15, maximumBytes: 16_384)
                    guard current(), account.exitCode == 0,
                          let verified = try? JSONDecoder().decode(Plan.self, from: account.stdout),
                          verified.owner == owner, verified.config_dir == plan.config_dir else {
                        try save("outcome_unknown", "The requested session is bound but its original account was not reverified. Do not replay."); return
                    }
                    try save("verified", "Exact saved Codex session resumed; pane, account, worker and shell preserved"); return
                }
                try await Task.sleep(for: .seconds(1))
            }
            try save("outcome_unknown", "Resume was submitted once; the expected native binding was not confirmed. Inspect; do not replay.")
        } catch {
            try? save(inputSent ? "outcome_unknown" : "refused", error.localizedDescription)
        }
    }
    static func sameRetainedShell(_ before: RelayPromptOwnerBinding, _ after: RelayPromptOwnerBinding) -> Bool {
        before.paneId == after.paneId && before.nodeBootId == after.nodeBootId && before.workerPid == after.workerPid && before.workerStart == after.workerStart && before.shellPid == after.shellPid && before.shellStart == after.shellStart
    }
    static func verified(_ before: RelayPromptOwnerBinding, after: RelayPromptOwnerBinding, target: UUID) -> Bool {
        sameRetainedShell(before, after) && after.provider == "codex" && after.inputOnly != true && after.sessionId == target.uuidString.lowercased() && (before.processId != after.processId || before.processStart != after.processStart)
    }
}
