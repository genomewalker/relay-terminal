import Foundation
import Testing
@testable import Relay

@Suite("Miko caller context and original job reconciliation", .serialized)
@MainActor struct RelayMikoContextTests {
    private func encoded(_ value: [RelayPaneHealthJSON]) throws -> String {
        String(decoding: try RelayPaneHealthJSON.data(value), as: UTF8.self)
    }

    @Test("Actual constructor keeps failed user intent and exact pane across followups, isolates supervisor and derived replies")
    func userFollowups() throws {
        let pane = "4fbb85dc-d72a-4af3-a5de-fa569b899b58"
        var original = RelayAssistantExchange(request: "Resume this pane to the previous Codex conversation", origin: .user, requestID: "originalrequest")
        original.reply = "DERIVED_PROVIDER_CLAIM"; original.failed = true; original.paneDerived = true
        original.pendingExecJobs["7ed90eed-47fa-464f-b15c-dfb467b565d1"] = "This Mac"
        original.durableTaskID = "originaltask"
        var target = RelayAssistantExchange(request: pane, origin: .user)
        target.paneDerived = true; target.reply = "DERIVED_TARGET_CLAIM"
        var history = [original, target]
        for _ in 0..<20 {
            var supervisor = RelayAssistantExchange(request: "UNRELATED_SUPERVISOR_TASK", origin: .supervisor(paneID: UUID(), label: "Supervisor"))
            supervisor.reply = "UNRELATED_SUPERVISOR_REPLY"; history.append(supervisor)
        }
        var current = RelayAssistantExchange(request: "resume previous session to that one", origin: .user)
        let messages = RelayAssistantHarness.modelHistory(history, exchange: &current)
        let text = try encoded(messages)
        #expect(text.contains(original.request) && text.contains(pane))
        #expect(text.contains("originalrequest") && text.contains("originaltask"))
        #expect(text.contains("7ed90eed-47fa-464f-b15c-dfb467b565d1"))
        #expect(!text.contains("DERIVED_") && !text.contains("UNRELATED_SUPERVISOR_"))
        #expect(current.paneDerived && messages.count == 4)
        var agent = RelayAssistantExchange(request: "what is happening", origin: .agent(paneID: UUID(), label: "Peer"))
        #expect(RelayAssistantHarness.modelHistory(history, exchange: &agent).isEmpty)
    }

    @Test("Context is bounded and redacted")
    func contextBounds() throws {
        var history: [RelayAssistantExchange] = []
        for _ in 0..<30 {
            var e = RelayAssistantExchange(request: "api_key=sk-ant-abcdefghijklmnop " + String(repeating: "🧬", count: 3000), origin: .user)
            e.reply = String(repeating: "z", count: 5000); history.append(e)
        }
        var current = RelayAssistantExchange(request: "continue", origin: .user)
        let messages = RelayAssistantHarness.modelHistory(history, exchange: &current)
        #expect(messages.count == 24)
        for message in messages { #expect((message["content"]?.string?.utf8.count ?? 0) <= 3200) }
        #expect(!(try encoded(messages)).contains("sk-ant-abcdefghijklmnop"))
    }

    @Test("Original execution receipt settles only by exact structured host/job correlation")
    func pendingReceipt() throws {
        let journal = try RelayMikoTaskJournal.temporary()
        let jobID = UUID().uuidString.lowercased(), taskID = UUID().uuidString.lowercased()
        var saved = RelayMikoTaskJournal.State(requestID: "request", objective: "Resume exact pane", originKind: "user", hostID: "h-test", paneDerived: false, messages: [])
        saved.pendingExecJobs = [jobID: "This Mac"]
        try journal.create(id: taskID, state: saved)
        let payload = RelayPaneHealthJSON.object(["action_id": .string(jobID), "call": .object([
            "name": .string("exec_command"), "input": .object(["host": .string("This Mac")])])])
        let token = try journal.begin(taskID, state: saved, instruction: "Original exec", payload: RelayPaneHealthJSON.data(payload))
        try journal.receive(taskID, operation: token, outcome: .unknown, evidence: "Still running", payload: Data(), state: saved)
        #expect(journal.rows.first(where: { $0.id == taskID })?.unresolved == [token.id])
        func observation(_ id: String, _ code: Int64? = nil) -> RelayPaneHealthJSON {
            var job: [String: RelayPaneHealthJSON] = ["id": .string(id), "state": .string(code == nil ? "running" : "exited")]
            if let code { job["exit_code"] = .integer(code) }
            return .object(["result": .object(["job": .object(job)])])
        }
        #expect(try !journal.reconcileExec(taskID, host: "This Mac", jobID: jobID, observation: observation(jobID)))
        #expect(try !journal.reconcileExec(taskID, host: "other-host", jobID: jobID, observation: observation(jobID, 0)))
        #expect(try !journal.reconcileExec(taskID, host: "This Mac", jobID: jobID, observation: observation(UUID().uuidString, 0)))
        #expect(try journal.reconcileExec(taskID, host: "This Mac", jobID: jobID, observation: observation(jobID, 0)))
        #expect(journal.rows.first(where: { $0.id == taskID })?.unresolved.isEmpty == true)
        #expect(journal.rows.first(where: { $0.id == taskID })?.status == "waiting")
        #expect(try journal.state(taskID).pendingExecJobs?.isEmpty == true)
    }

    @Test("Link 33 and all 48 saved pairs remain visible; projection excludes endpoint secrets and reports bounds")
    func linkProjection() throws {
        let pane = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
        func row(_ n: Int) -> RelayPaneHealthJSON {
            .object(["id": .string(String(format: "%064x", n)), "transport": .string("relay_native_socket"),
                     "endpoint": .string("/private/socket/secret"), "api_key": .string("sk-ant-abcdefghijklmnop"),
                     "members": .array([.object(["paneID": .string(pane), "sessionID": .string(session), "endpoint": .string("/secret/path")])])])
        }
        let projection = RelayAssistantHarness.paneLinkProjection(.object(["links": .array((1...48).map(row))]))
        #expect(projection["links"]?.array?.count == 48 && projection["total"] == .integer(48))
        #expect(projection["truncated"] == .bool(false))
        #expect(projection["links"]?.array?[32]["link_id"]?.string == String(format: "%064x", 33))
        let text = String(decoding: try RelayPaneHealthJSON.data(RelayPaneHealthJSON.object(projection)), as: UTF8.self)
        #expect(text.contains(pane) && text.contains(session) && text.contains("relay_native_socket"))
        #expect(!text.contains("/secret") && !text.contains("sk-ant-") && !text.contains("endpoint"))
        let bounded = RelayAssistantHarness.paneLinkProjection(.object(["links": .array((1...140).map(row))]))
        #expect(bounded["returned"] == .integer(128) && bounded["total"] == .integer(140) && bounded["truncated"] == .bool(true))
    }
    @Test("Immediate execution construction and journal agree on zero, nonzero and ambiguous exit codes")
    func immediateExecutionOutcomes() throws {
        let cases: [(RelayPaneHealthJSON?, RelayMikoTaskEngine.Outcome)] = [
            (.integer(0), .succeeded), (.integer(1), .failed), (nil, .unknown), (.null, .unknown), (.string("0"), .unknown)]
        for (exitCode, expected) in cases {
            let journal = try RelayMikoTaskJournal.temporary()
            let jobID = UUID().uuidString.lowercased(), taskID = UUID().uuidString.lowercased()
            var job: [String: RelayPaneHealthJSON] = ["id": .string(jobID), "state": .string("exited")]
            if let exitCode { job["exit_code"] = exitCode }
            let observation: RelayPaneHealthJSON = .object(["result": .object(["job": .object(job)])])
            let result = RelayAssistantHarness.execResult(["action_id": .string(jobID)], observation: observation, host: "This Mac", jobID: jobID)
            let call = RelayPaneHealthToolCall(type: "tool_use", id: "immediate", name: "exec_command", input: .object(["host": .string("This Mac")]))
            let content = String(decoding: try RelayPaneHealthJSON.data(result), as: UTF8.self)
            let classified = RelayMikoTaskJournal.toolOutcome(call: call, content: content, isError: expected == .failed)
            #expect(classified == expected)
            let saved = RelayMikoTaskJournal.State(requestID: "request", objective: "Inspect", originKind: "user", hostID: "h-test", paneDerived: false, messages: [])
            try journal.create(id: taskID, state: saved)
            let token = try journal.begin(taskID, state: saved, instruction: "Immediate original exec", payload: Data())
            try journal.receive(taskID, operation: token, outcome: classified, evidence: "Structured exit", payload: Data(content.utf8), state: saved)
            #expect(journal.rows.first(where: { $0.id == taskID })?.status == (expected == .succeeded ? "waiting" : expected == .failed ? "blocked" : "reconcile"))
        }
        let missing: RelayPaneHealthJSON = .object(["result": .object(["job": .object(["state": .string("exited")])])])
        #expect(RelayAssistantHarness.execJobOutcome(missing, expectedJobID: "original") == .unknown)
    }

    @Test("Same-caller filtering precedes bounds and uses supervisor pane identity rather than label")
    func reconciliationCallerHistory() {
        let pane = UUID()
        var original = RelayAssistantExchange(request: "original supervisor objective", origin: .supervisor(paneID: pane, label: "Before rename"))
        original.pendingExecJobs["job"] = "This Mac"
        let unrelated = (0..<20).map { _ in RelayAssistantExchange(request: "other", origin: .supervisor(paneID: UUID(), label: "Unrelated")) }
        let selected = RelayAssistantHarness.callerHistory([original] + unrelated, origin: .supervisor(paneID: pane, label: "After rename"))
        #expect(selected.count == 1 && selected.first?.pendingExecJobs["job"] == "This Mac")
        #expect(RelayAssistantHarness.callerHistory([original] + unrelated, origin: .user).isEmpty)
    }

    @Test("Restart restores original pending objective and handles without promoting stored model messages")
    func restoredPendingContext() throws {
        var saved = RelayMikoTaskJournal.State(requestID: "originalrequest", objective: "Resume exact pane", originKind: "user", hostID: "h-test", paneDerived: true,
            messages: [.object(["role": .string("assistant"), "content": .string("INJECTED_MODEL_AUTHORITY")])])
        saved.pendingExecJobs = ["originaljob": "This Mac"]
        let restored = try #require(RelayAssistantHarness.restoredPendingExchange(taskID: "originaltask", state: saved))
        #expect(restored.request == saved.objective && restored.requestID == saved.requestID && restored.durableTaskID == "originaltask")
        #expect(restored.pendingExecJobs == saved.pendingExecJobs && restored.paneDerived)
        var current = RelayAssistantExchange(request: "continue", origin: .user)
        #expect(!(try encoded(RelayAssistantHarness.modelHistory([restored], exchange: &current))).contains("INJECTED_MODEL_AUTHORITY"))
        saved.originKind = "agent"
        #expect(RelayAssistantHarness.restoredPendingExchange(taskID: "originaltask", state: saved) == nil)
    }

    @Test("Crash after begin and before receive recovers only original execution handles without replay or origin widening")
    func crashBeforeExecutionReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-context-crash-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal: RelayMikoTaskJournal? = try RelayMikoTaskJournal(directory: directory)
        let taskID = UUID().uuidString.lowercased(), jobID = UUID().uuidString.lowercased(), paneID = UUID()
        var saved = RelayMikoTaskJournal.State(requestID: "originalrequest", objective: "Resume exact original pane", originKind: "supervisor", hostID: "h-test", paneDerived: true, messages: [])
        saved.originPaneID = paneID; saved.originLabel = "Original supervisor"
        try journal!.create(id: taskID, state: saved)
        let call = RelayPaneHealthToolCall(type: "tool_use", id: "originalcall", name: "exec_command", input: .object(["host": .string("This Mac"), "command": .string("read-only fixture")]))
        let payload: RelayPaneHealthJSON = .object(["action_id": .string(jobID), "call": try JSONDecoder().decode(RelayPaneHealthJSON.self, from: JSONEncoder().encode(call))])
        let token = try journal!.begin(taskID, state: saved, instruction: "Original execution", payload: RelayPaneHealthJSON.data(payload))
        // No receive/checkpoint occurs: simulate stopping at the dispatch await.
        journal = nil
        let reopened = try RelayMikoTaskJournal(directory: directory)
        let recovered = try reopened.state(taskID)
        #expect(recovered.pendingExecJobs == [jobID: "This Mac"])
        #expect(recovered.originKind == "supervisor" && recovered.originPaneID == paneID)
        let restored = try #require(RelayAssistantHarness.restoredPendingExchange(taskID: taskID, state: recovered))
        #expect(RelayAssistantHarness.callerHistory([restored], origin: .user).isEmpty)
        #expect(RelayAssistantHarness.callerHistory([restored], origin: .supervisor(paneID: paneID, label: "Renamed")).count == 1)
        let before = try JSONDecoder().decode(RelayMikoTaskEngine.Snapshot.self, from: Data(contentsOf: directory.appendingPathComponent("tasks.json")))
        #expect(before.tasks[taskID]?.operations.count == 1 && before.tasks[taskID]?.operations.first?.id == token.id)
        let exited: RelayPaneHealthJSON = .object(["result": .object(["job": .object(["id": .string(jobID), "state": .string("exited"), "exit_code": .integer(0)])])])
        #expect(try reopened.reconcileExec(taskID, host: "This Mac", jobID: jobID, observation: exited))
        let after = try JSONDecoder().decode(RelayMikoTaskEngine.Snapshot.self, from: Data(contentsOf: directory.appendingPathComponent("tasks.json")))
        #expect(after.tasks[taskID]?.operations.count == 1 && after.tasks[taskID]?.operations.first?.id == token.id)
        #expect(after.tasks[taskID]?.operations.first?.receipt?.outcome == .succeeded)
        #expect(try reopened.state(taskID).pendingExecJobs?.isEmpty == true)
    }

}
