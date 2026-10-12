import AppKit
import Foundation

/// Structured R commands only. Generic terminal input keeps its separate approval.
@MainActor
final class RAutomationController {
    static let shared = RAutomationController()
    private struct Binding {
        let console: PaneModel
        let editor: PaneModel
        let scope: PluginScope
        let session: RWorkspaceSession
    }
    private struct State {
        var admission = RExecutionAdmission()
        var target: RExecutionTarget
        var console: PaneModel
        var editor: PaneModel
        var revision: UInt64 = 0
    }
    private var states: [UUID: State] = [:]
    private var resolving = false
    private var authorizations: [UUID: [String: String]] = [:]
    private var authorizationTargets: [UUID: String] = [:]
    private var directExecutions: [UUID: RDirectExecution] = {
        guard let data = UserDefaults.standard.data(forKey: "relay.r-direct-execution.v1") else { return [:] }
        return (try? JSONDecoder().decode([UUID: RDirectExecution].self, from: data)) ?? [:]
    }()
    private var directMirrors: [UUID: UUID] = [:]
    private let persistenceKey = "relay.r-linked-execution.v1"

    private func persistDirect() {
        if let data = try? JSONEncoder().encode(directExecutions) {
            UserDefaults.standard.set(data, forKey: "relay.r-direct-execution.v1")
        }
    }

    private func directOutput(_ record: RDirectExecution, paneID: UUID) {
        let id = record.id
        guard directExecutions[id]?.sessionID == record.sessionID,
              states[paneID]?.target.sessionID == record.sessionID else { return }
        directExecutions[id] = record
        try? observeCompletion(paneID: paneID, id: id, sessionID: record.sessionID, status: record.status)
        if states[paneID]?.editor.editorRuntime.rSession?.session_id == record.sessionID {
            states[paneID]?.editor.editorRuntime.noteRCompletion(id, status: record.status)
        }
        if ["completed", "error", "interrupted"].contains(record.status), let mirror = directMirrors.removeValue(forKey: id) {
            states[paneID]?.console.runtime.endSidePanelTerminalMirror(mirror)
        }
        persistDirect()
    }

    private func watchDirect(paneID: UUID, id: UUID, binding: Binding) async throws {
        guard directMirrors[id] == nil else { return }
        guard let record = directExecutions[id] else { throw PluginError.invalid("Direct request unavailable") }
        let monitor = RDirectExecutionMonitor(record)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let mirror = binding.console.runtime.beginSidePanelTerminalMirror(
                deliver: { [weak self] data in
                    if let result = monitor.receive(data) {
                        Task { @MainActor in self?.directOutput(result, paneID: paneID) }
                    }
                }, viewportChanged: { _ in },
                ready: { [weak self] data, _ in
                    let result = monitor.receive(data)
                    Task { @MainActor in
                        if let result { self?.directOutput(result, paneID: paneID) }
                        continuation.resume()
                    }
                }) else {
                continuation.resume(throwing: PluginError.invalid("Direct execution requires a connected Relay terminal"))
                return
            }
            directMirrors[id] = mirror
        }
    }

    private func savedStates() -> [UUID: RExecutionAdmission.Snapshot] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let value = try? JSONDecoder().decode([UUID: RExecutionAdmission.Snapshot].self, from: data) else { return [:] }
        return value
    }

    private func persist(_ paneID: UUID) {
        var saved = savedStates()
        saved[paneID] = states[paneID]?.admission.snapshot
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: persistenceKey) }
    }

    private func restore(_ paneID: UUID, binding: Binding) {
        guard states[paneID] == nil, let saved = savedStates()[paneID],
              saved.target.sessionID == binding.session.session_id,
              saved.target.projectRoot == binding.scope.root,
              saved.target.host == binding.console.profile.connectionKey else { return }
        var state = State(target: saved.target, console: binding.console, editor: binding.editor)
        state.admission = RExecutionAdmission(restoring: saved)
        state.revision = binding.console.agentInputRevision
        states[paneID] = state
    }

    private func binding(_ paneID: UUID, workspace: WorkspaceModel, expected: String) async throws -> Binding {
        guard let console = workspace.panes[paneID], console.contentKind == .terminal,
              console.connectionState == .connected,
              let editor = workspace.panes.values.first(where: {
                  $0.contentKind == .editor && $0.remoteParentSessionID.flatMap(UUID.init(uuidString:)) == paneID &&
                  $0.profile.connectionKey == console.profile.connectionKey && $0.editorRuntime.rSession?.session_id == expected
              }), let scope = editor.editorRuntime.rResultsScope,
              let saved = editor.editorRuntime.rSession else {
            throw PluginError.invalid("Open the linked R editor and connect its companion first")
        }
        let response = try await PluginOperationRunner.run(.artifacts, scope: scope,
            path: editor.editorRuntime.rArtifactRelative + "/session.json")
        guard let data = response.verifiedBytes else { throw PluginError.invalid("R session snapshot unavailable") }
        let fresh = try JSONDecoder().decode(RWorkspaceSession.self, from: data)
        try fresh.validate(root: saved.artifact_root)
        guard fresh.session_id == expected, fresh.pid == saved.pid,
              workspace.panes[paneID] === console, workspace.panes[editor.id] === editor,
              editor.editorRuntime.rSession?.session_id == expected,
              console.connectionState == .connected else {
            states[paneID]?.admission.revoke()
            throw PluginError.invalid("R session changed; authorize the new session")
        }
        return Binding(console: console, editor: editor, scope: scope, session: fresh)
    }

    func authorize(paneID: UUID, expected: String, id: UUID, workspace: WorkspaceModel) async throws -> [String: String] {
        let identity = paneID.uuidString + ":" + expected
        if let old = authorizations[id] {
            guard authorizationTargets[id] == identity else { throw PluginError.invalid("Authorization request ID belongs to another session") }
            return old
        }
        guard authorizations.count < 256 else { throw PluginError.invalid("Authorization receipt capacity reached") }
        guard !resolving else { throw PluginError.invalid("R operation is pending") }
        resolving = true
        defer { resolving = false }
        let binding = try await binding(paneID, workspace: workspace, expected: expected)
        restore(paneID, binding: binding)
        guard states[paneID]?.admission.active == nil,
              RWorkspaceIdlePrompt.accepts(binding.console.runtime.sidePanelViewportText()) else {
            throw PluginError.invalid("Wait for the idle R console and resolve any outstanding operation")
        }
        let target = RExecutionTarget(paneID: paneID, host: binding.console.profile.connectionKey,
            projectRoot: binding.scope.root, sessionID: expected, connectionGeneration: UUID())
        authorizationTargets[id] = identity
        var state = states[paneID] ?? State(target: target, console: binding.console, editor: binding.editor)
        if state.target.sessionID != expected || state.target.projectRoot != binding.scope.root ||
           state.target.host != binding.console.profile.connectionKey {
            state = State(target: target, console: binding.console, editor: binding.editor)
        }
        try state.admission.authorize(RExecutionGrant(id: id, target: state.target,
            actors: ["authenticated_relay_mcp"], expiresAt: .now.advanced(by: .seconds(315_360_000)), maximumRuns: 256))
        state.revision = binding.console.agentInputRevision
        states[paneID] = state
        persist(paneID)
        authorizations[id] = ["request_id": id.uuidString.lowercased(), "pane_id": paneID.uuidString.lowercased(), "status": "authorized"]
        return authorizations[id]!
    }

    func pause(_ paneID: UUID) -> [String: String] {
        if states[paneID] == nil, var saved = savedStates()[paneID] {
            saved = RExecutionAdmission.Snapshot(target: saved.target, paused: true, active: saved.active,
                receipts: saved.receipts, admittedRuns: saved.admittedRuns)
            var all = savedStates(); all[paneID] = saved
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: persistenceKey) }
        }
        states[paneID]?.admission.pause()
        if states[paneID] != nil { persist(paneID) }
        return ["status": "paused", "pane_id": paneID.uuidString.lowercased()]
    }

    func authorizationReceipt(_ id: UUID) -> [String: String]? { authorizations[id] }

    /// Observe native admission state only: no handshake reads, authorization,
    /// R input, reconciliation, or liveness claims.
    func sessionStatus(paneID: UUID, workspace: WorkspaceModel) throws -> [String: Any] {
        guard let console = workspace.panes[paneID], console.contentKind == .terminal else {
            throw PluginError.invalid("Select the R console pane")
        }
        let snapshot = states[paneID]?.admission.snapshot ?? savedStates()[paneID]
        let paused = states[paneID]?.admission.paused ?? snapshot?.paused ?? true
        let active = states[paneID]?.admission.active ?? snapshot?.active
        let linked = workspace.panes.values.first { $0.contentKind == .editor &&
            $0.remoteParentSessionID.flatMap(UUID.init(uuidString:)) == paneID &&
            $0.profile.connectionKey == console.profile.connectionKey }
        let currentSession = linked?.editorRuntime.rSession?.session_id
        let matching = snapshot?.target.sessionID == currentSession && currentSession != nil
        let idle = RWorkspaceIdlePrompt.accepts(console.runtime.sidePanelViewportText())
        let state = snapshot == nil ? "not_authorized" : (paused ? "paused" : (active == nil ? "authorized" : "run_unresolved"))
        return ["pane_id": paneID.uuidString.lowercased(), "status": state,
            "paused": paused, "active_request_id": active?.uuidString.lowercased() as Any? ?? NSNull(),
            "active_status": active.flatMap { snapshot?.receipts[$0]?.status.rawValue } as Any? ?? NSNull(),
            "session_id": snapshot?.target.sessionID as Any? ?? NSNull(),
            "current_session_id": currentSession as Any? ?? NSNull(), "session_identity_matches": matching,
            "console_connected": console.connectionState == .connected, "console_prompt_appears_idle": idle,
            "admitted_agent_runs": snapshot?.admittedRuns ?? 0,
            "dispatch_requires_fresh_validation": true, "liveness_verified": false,
            "human_console_completion_tracked": false,
            "next_action": paused ? "Wait for explicit user direction to resume agents; do not reauthorize to bypass human control." : "Inspect unresolved receipts and revalidate session/source before any user-authorized run."]
    }

    func execute(paneID: UUID, expected: String, id: UUID, code: String, workspace: WorkspaceModel, direct: Bool = false, source: RExecutionSource? = nil, human: Bool = false) async throws -> [String: String] {
        if human, states[paneID] == nil {
            _ = try await authorize(paneID: paneID, expected: expected, id: UUID(), workspace: workspace)
        }
        guard !resolving else { throw PluginError.invalid("R operation is pending") }
        resolving = true
        defer { resolving = false }
        let binding = try await binding(paneID, workspace: workspace, expected: expected)
        restore(paneID, binding: binding)
        guard var state = states[paneID], state.console === binding.console, state.editor === binding.editor,
              state.target.sessionID == expected, state.target.projectRoot == binding.scope.root else {
            throw PluginError.invalid("Authorize this exact R session before automatic execution")
        }
        let ownership: RConsoleOwnership = human ? .human : .automation
        let request = RExecutionAdmission.Request(id: id, actor: human ? "human_ui" : "authenticated_relay_mcp", target: state.target, code: code)
        if let receipt = state.admission.receipts[id] {
            guard receipt.request == request else { throw PluginError.invalid("Request ID belongs to different code") }
            if let record = directExecutions[id] {
                let expectedSource = source ?? RExecutionSource(kind: "provided_code", codeSHA256: RExecutionSource.digest(code))
                guard record.source == nil || record.source == expectedSource else {
                    throw PluginError.invalid("Request ID belongs to a different execution source")
                }
            }
            return ["request_id": id.uuidString.lowercased(), "status": receipt.status.rawValue, "replayed": "false"]
        }
        if !human, state.admission.paused { throw RExecutionAdmission.Rejection.paused }
        if human, state.admission.active == nil { state.revision = binding.console.agentInputRevision }
        guard state.revision == binding.console.agentInputRevision,
              RWorkspaceIdlePrompt.accepts(binding.console.runtime.sidePanelViewportText()) else {
            state.admission.pause()
            states[paneID] = state
            persist(paneID)
            throw PluginError.invalid("R console is not idle; automation paused")
        }
        if human {
            var record = RDirectExecution(id: id, sessionID: expected, code: code, source: source, humanConsole: true)
            let plainCode = try record.command(code: code)
            try state.admission.recordHumanConsoleDispatch(request)
            states[paneID] = state
            record.status = "sent_to_console"
            directExecutions[id] = record
            persist(paneID)
            persistDirect()
            guard binding.console.runtime.sendSidePanelPrompt(plainCode) else {
                directExecutions[id]?.status = "unknown"
                persistDirect()
                throw PluginError.invalid("Console delivery uncertain; do not resend automatically")
            }
            states[paneID]?.revision = binding.console.agentInputRevision
            binding.editor.editorRuntime.noteMCPExecution(id, source: record.source, human: true)
            return ["request_id": id.uuidString.lowercased(), "status": "sent_to_console", "completion": "unknown"]
        }
        let directRecord = direct ? RDirectExecution(id: id, sessionID: expected, code: code, source: source) : nil
        let command = try directRecord?.command(code: code) ?? RWorkspaceCommand.evaluate(code: code, id: id, root: binding.session.artifact_root, session: binding.session)
        if directRecord != nil {
            directExecutions[id] = directRecord
            persistDirect()
            try await watchDirect(paneID: paneID, id: id, binding: binding)
        }
        guard workspace.panes[paneID] === binding.console,
              workspace.panes[binding.editor.id] === binding.editor,
              binding.console.agentInputRevision == state.revision,
              binding.console.connectionState == .connected,
              RWorkspaceIdlePrompt.accepts(binding.console.runtime.sidePanelViewportText()) else {
            if let mirror = directMirrors.removeValue(forKey: id) { binding.console.runtime.endSidePanelTerminalMirror(mirror) }
            directExecutions.removeValue(forKey: id)
            persistDirect()
            throw PluginError.invalid("R console changed before dispatch; nothing executed")
        }
        if !human, let path = source?.path,
           workspace.panes.values.contains(where: { $0.contentKind == .editor &&
               $0.profile.connectionKey == binding.console.profile.connectionKey &&
               $0.editorRuntime.currentPath == path && $0.editorRuntime.isDirty }) {
            if let mirror = directMirrors.removeValue(forKey: id) { binding.console.runtime.endSidePanelTerminalMirror(mirror) }
            directExecutions.removeValue(forKey: id)
            persistDirect()
            throw PluginError.invalid("Resolve the human draft before agent execution")
        }
        do {
            _ = try state.admission.admit(request, mode: .execute, ownership: ownership)
            try state.admission.begin(id, target: state.target, mode: .execute, ownership: ownership)
        } catch {
            if let mirror = directMirrors.removeValue(forKey: id) { binding.console.runtime.endSidePanelTerminalMirror(mirror) }
            directExecutions.removeValue(forKey: id)
            persistDirect()
            throw error
        }
        states[paneID] = state
        persist(paneID)
        if !binding.console.runtime.sendSidePanelPrompt(command, maximumBytes: 128 << 10) {
            directExecutions[id]?.status = "unknown"
            persistDirect()
            try states[paneID]?.admission.finish(id, status: .unknown)
            persist(paneID)
            throw PluginError.invalid("Delivery uncertain; inspect this request receipt, do not resend")
        }
        binding.editor.editorRuntime.noteMCPExecution(id, source: directRecord?.source)
        states[paneID]?.revision = binding.console.agentInputRevision
        return ["request_id": id.uuidString.lowercased(), "status": "submitted", "completion": "unknown"]
    }

    func executeProjectFile(paneID: UUID, expected: String, id: UUID, path: String, sha256: String, workspace: WorkspaceModel) async throws -> [String: String] {
        let bound = try await binding(paneID, workspace: workspace, expected: expected)
        let absolute = try bound.scope.editorPath(path)
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "r" else { throw PluginError.invalid("Select an R project file") }
        func hasConflict() -> Bool {
            workspace.panes.values.contains { pane in
                pane.contentKind == .editor && pane.profile.connectionKey == bound.console.profile.connectionKey &&
                pane.editorRuntime.currentPath == absolute && pane.editorRuntime.isDirty
            }
        }
        guard !hasConflict() else { throw PluginError.invalid("Resolve the human draft for this file before agent execution") }
        let response = try await PluginOperationRunner.run(.artifacts, scope: bound.scope, path: path)
        guard let bytes = response.verifiedBytes else { throw PluginError.invalid("Project file could not be captured") }
        let snapshot = try RProjectExecutionSnapshot.capture(bytes, path: absolute, expectedSHA256: sha256)
        guard !hasConflict() else { throw PluginError.invalid("A human draft changed during file capture") }
        return try await execute(paneID: paneID, expected: expected, id: id, code: snapshot.code, workspace: workspace, direct: true, source: snapshot.source)
    }

    func observeCompletion(paneID: UUID, id: UUID, sessionID: String, status: String) throws {
        guard let state = states[paneID], state.target.sessionID == sessionID,
              let receipt = state.admission.receipts[id], state.admission.active == id else { return }
        let terminal: RExecutionAdmission.Status
        switch status {
        case "completed": terminal = .completed
        case "error": terminal = .failed
        case "interrupted": terminal = .interrupted
        default: return
        }
        if receipt.status == .unknown { try states[paneID]?.admission.reconcile(id, status: terminal) }
        else { try states[paneID]?.admission.finish(id, status: terminal) }
        persist(paneID)
    }

    func result(paneID: UUID, id: UUID, workspace: WorkspaceModel) async throws -> [String: Any] {
        if states[paneID] == nil, let saved = savedStates()[paneID] {
            let binding = try await binding(paneID, workspace: workspace, expected: saved.target.sessionID)
            restore(paneID, binding: binding)
        }
        guard let state = states[paneID], let receipt = state.admission.receipts[id] else {
            throw PluginError.invalid("Unknown R request; never retry an uncertain execution")
        }
        let binding = try await binding(paneID, workspace: workspace, expected: state.target.sessionID)
        if let record = directExecutions[id] {
            if record.humanConsole == true { return record.receipt }
            if !["completed", "error", "interrupted"].contains(record.status) {
                try await watchDirect(paneID: paneID, id: id, binding: binding)
            }
            return (directExecutions[id] ?? record).receipt
        }
        let response = try await PluginOperationRunner.run(.artifacts, scope: binding.scope,
            path: binding.editor.editorRuntime.rArtifactRelative + "/" + id.uuidString.lowercased() + "/result.json")
        guard let bytes = response.verifiedBytes, bytes.count <= 2 << 20,
              let record = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              record["request_id"] as? String == id.uuidString.lowercased(),
              record["session_id"] as? String == state.target.sessionID else {
            throw PluginError.invalid("Result identity mismatch; execution remains unresolved")
        }
        let status = record["status"] as? String
        let terminal: RExecutionAdmission.Status? = status == "completed" ? .completed : status == "error" ? .failed : status == "interrupted" ? .interrupted : nil
        if let terminal, states[paneID]?.admission.active == id {
            if receipt.status == .unknown { try states[paneID]?.admission.reconcile(id, status: terminal) }
            else { try states[paneID]?.admission.finish(id, status: terminal) }
            persist(paneID)
        }
        if let status { binding.editor.editorRuntime.noteRCompletion(id, status: status) }
        return record
    }
}
