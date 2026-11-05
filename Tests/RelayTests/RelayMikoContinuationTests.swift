import Foundation
import Testing
import Combine
@testable import Relay

@MainActor private final class ContinuationModel: RelayAssistantModel {
    var requests: [RelayAssistantModelRequest] = []
    var handler: (RelayAssistantModelRequest, Int) throws -> RelayAssistantModelStep
    init(_ handler: @escaping (RelayAssistantModelRequest, Int) throws -> RelayAssistantModelStep) { self.handler = handler }
    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        requests.append(request)
        return try handler(request, requests.count)
    }
}

@Suite("Miko durable continuation", .serialized, .timeLimit(.minutes(1)))
@MainActor struct RelayMikoContinuationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-continuation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func state() -> RelayMikoTaskJournal.State {
        .init(requestID: "originalrequest", objective: "Inspect every pane", originKind: "user",
              hostID: "h-test", paneDerived: true,
              messages: [.object(["role": .string("user"), "content": .string("Inspect every pane")])])
    }
    private func answer(_ text: String) -> RelayAssistantModelStep {
        .init(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string(text)])],
              toolCalls: [], chargedMicrousd: 1)
    }
    private func tool(_ n: Int) -> RelayAssistantModelStep {
        let call = RelayPaneHealthToolCall(type: "tool_use", id: "call-\(n)", name: "list_panes",
                                          input: .object(["query": .string("unique-\(n)")]))
        return .init(stopReason: "tool_use", content: [.object(["type": .string("tool_use"), "id": .string(call.id),
            "name": .string(call.name), "input": call.input])], toolCalls: [call], chargedMicrousd: 1)
    }
    private func harness(_ workspace: WorkspaceModel, model: ContinuationModel, journal: RelayMikoTaskJournal) throws -> RelayAssistantHarness {
        let audit = RelayCallerControl(directory: try directory())
        return RelayAssistantHarness(policy: { .init() }, budget: RelayMikoActionBudget(), workspace: workspace,
                                     model: { _ in (model, "h-test") }, audit: audit, taskJournal: journal)
    }

    @Test("Checkpoint retains exact targets and usable schema fields, permits safe refresh")
    func checkpointRetainsOperatorEvidence() throws {
        var saved = state()
        saved.modelContext = "old model prefix"
        let pane = "90a0f5b3-0cd9-4e54-9bd1-3239b6fd8bc0"
        let request = "request-exact-fixture"
        let schema = RelayPaneHealthJSON.object([
            "name": .string("relay_move_pane_account"),
            "description": .string(String(repeating: "description ", count: 500)),
            "inputSchema": .object([
                "properties": .object(["pane_id": .object(["type": .string("string")]), "request_id": .object(["type": .string("string")])]),
                "required": .array([.string("pane_id"), .string("request_id")]),
                "additionalProperties": .bool(false)
            ])
        ])
        let discover = RelayPaneHealthToolCall(type: "tool_use", id: "schema", name: "relay_tools",
            input: .object(["tool_name": .string("relay_move_pane_account")]))
        saved.record(call: discover, content: String(decoding: try RelayPaneHealthJSON.data(schema), as: UTF8.self), outcome: "succeeded")
        let args = #"{"pane_id":"\#(pane)","request_id":"\#(request)","account":"business"}"#
        let call = RelayPaneHealthToolCall(type: "tool_use", id: "move", name: "relay_tool_call",
            input: .object(["tool_name": .string("relay_move_pane_account"), "arguments_json": .string(args)]))
        saved.record(call: call, content: #"{"status":"refused","message":"unfinished subagent"}"#, outcome: "failed")
        saved.rotate(userTurn: "Continue the same migration")
        let checkpoint = try #require(saved.messages[1]["content"]?.string)
        let instruction = try #require(saved.messages[2]["content"]?.string)
        #expect(checkpoint.contains(pane) && checkpoint.contains(request))
        #expect(checkpoint.contains("allowed_fields") && checkpoint.contains("request_id"))
        #expect(checkpoint.contains("Re-read schemas/status"))
        #expect(instruction.contains("Safe reads may be repeated"))
        #expect(instruction.contains("Never replay settled or unresolved mutations"))
        #expect(saved.modelContext == nil)
    }

    @Test("Host-sized windows complete more than eight tools without raising host limits")
    func boundedWindows() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let journal = try RelayMikoTaskJournal.temporary()
        var counts: [String: Int] = [:]
        var prefixes: [String: Set<String>] = [:]
        let model = ContinuationModel { request, count in
            counts[request.requestID, default: 0] += 1
            prefixes[request.requestID, default: []].insert(request.context)
            // Changing native selection must not rewrite the signed model prefix.
            workspace.activePaneID = UUID()
            #expect(counts[request.requestID, default: 0] <= 9)
            let historyTools = request.messages.flatMap { $0["content"]?.array ?? [] }
                .filter { $0["type"]?.string == "tool_result" }.count
            #expect(historyTools < 8)
            #expect(request.messages.count <= 48 && request.messages.count % 2 == 1)
            for (index, message) in request.messages.enumerated() {
                #expect(message["role"]?.string == (index % 2 == 0 ? "user" : "assistant"))
                if index % 2 == 1 {
                    let proposed = (message["content"]?.array ?? []).filter { $0["type"]?.string == "tool_use" }
                    if !proposed.isEmpty, index + 1 < request.messages.count {
                        let returned = request.messages[index + 1]["content"]?.array ?? []
                        #expect(Set(proposed.compactMap { $0["id"]?.string }) ==
                                Set(returned.compactMap { $0["tool_use_id"]?.string }))
                    }
                }
            }
            return count <= 18 ? tool(count) : answer("All panes inspected.")
        }
        let assistant = try harness(workspace, model: model, journal: journal)
        let exchange = try #require(await assistant.run("Inspect every pane", origin: .user))
        #expect(exchange.reply == "All panes inspected." && !exchange.failed)
        #expect(model.requests.count == 19 && counts.count == 3)
        #expect(prefixes.values.allSatisfy { $0.count == 1 })
        #expect(Set(prefixes.values.compactMap { $0.first }).count == 3)
        #expect(Set(model.requests.map(\.operationID)).count == 19)
        let row = try #require(journal.rows.first)
        #expect(row.status == "reportedComplete" && row.unresolved.isEmpty)
        let saved = try journal.state(row.id)
        #expect(saved.objective == "Inspect every pane" && saved.totalTools == 18 && saved.window == 2)
        #expect(saved.paneDerived)
    }

    @Test("Failed intent persistence prevents the model from being called")
    func noDispatchWithoutPersistence() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RelayMikoTaskJournal(directory: dir, persist: { data, url in
            let snapshot = try JSONDecoder().decode(RelayMikoTaskEngine.Snapshot.self, from: data)
            if snapshot.tasks.values.contains(where: { !$0.operations.isEmpty }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let model = ContinuationModel { _, _ in answer("Must not run") }
        let exchange = try #require(await harness(workspace, model: model, journal: journal).run("Check panes", origin: .user))
        #expect(exchange.failed && model.requests.isEmpty)
        #expect(journal.rows.first?.unresolved.isEmpty == true)
    }

    @Test("Ambiguous model outcome remains unresolved and is never retried")
    func unknownModelStops() async throws {
        let journal = try RelayMikoTaskJournal.temporary()
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let model = ContinuationModel { _, _ in throw RelayAssistantModelFailure.refused("reconciliation_required") }
        let assistant = try harness(workspace, model: model, journal: journal)
        let exchange = try #require(await assistant.run("Check panes", origin: .user))
        #expect(exchange.failed && model.requests.count == 1)
        let row = try #require(journal.rows.first)
        #expect(row.status == "reconcile" && row.unresolved.count == 1 && !row.canContinue)
        assistant.continueTask(row.id)
        #expect(model.requests.count == 1)
    }

    @Test("Restart preserves unresolved dispatch and rejects a second ledger owner")
    func restartAndOwnership() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var journal: RelayMikoTaskJournal? = try RelayMikoTaskJournal(directory: dir)
        try journal?.create(id: "fixture", state: state())
        let attempt = try journal?.begin("fixture", state: state(), instruction: "Read panes", payload: Data("intent".utf8))
        let token = try #require(attempt)
        #expect(throws: (any Error).self) { try RelayMikoTaskJournal(directory: dir) }
        journal = nil
        let reopened = try RelayMikoTaskJournal(directory: dir)
        let row = try #require(reopened.rows.first)
        #expect(row.status == "reconcile" && row.unresolved == [token.id] && !row.canContinue)
        #expect(try reopened.state("fixture").paneDerived)
    }

    @Test("Receipt and pending cursor remain unchanged when their atomic save fails")
    func atomicResponseCheckpoint() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fail = false
        let journal = try RelayMikoTaskJournal(directory: dir, persist: { data, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let initial = state()
        try journal.create(id: "fixture", state: initial)
        let token = try journal.begin("fixture", state: initial, instruction: "Model", payload: Data("request".utf8))
        var next = initial
        next.totalTools = 1
        fail = true
        #expect(throws: (any Error).self) {
            try journal.receive("fixture", operation: token, outcome: .succeeded, evidence: "response",
                                payload: Data("response".utf8), state: next)
        }
        #expect(try journal.state("fixture").totalTools == 0)
        #expect(journal.rows.first?.unresolved == [token.id])
    }

    @Test("Stop during a model step persists cancellation and does not dispatch proposed tools")
    func cancellationPersists() async throws {
        let journal = try RelayMikoTaskJournal.temporary()
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        var assistant: RelayAssistantHarness?
        let model = ContinuationModel { _, _ in
            assistant?.cancel()
            return tool(1)
        }
        assistant = try harness(workspace, model: model, journal: journal)
        let exchange = try #require(await assistant?.run("Check panes", origin: .user))
        #expect(exchange.failed && exchange.toolTrace.isEmpty && model.requests.count == 1)
        #expect(journal.rows.first?.status == "cancelled")
    }

    @Test("Structured pending and ambiguous receipts block continuation; pane prose cannot settle them")
    func outcomes() {
        let call = RelayPaneHealthToolCall(type: "tool_use", id: "fixture", name: "relay_tool_call", input: .object([:]))
        for text in [
            #"{"outcome":"unknown"}"#,
            #"{"status":"submitted_outcome_unknown"}"#,
            #"{"outcome":"ran","response":"{\"result\":{\"job\":{\"state\":\"running\"}}}"}"#,
            #"{"error":"Outcome unresolved: completion audit failed. Do not replay."}"#,
            #"{"outcome":"ran","response":"truncated {"}"#
        ] {
            #expect(RelayMikoTaskJournal.toolOutcome(call: call, content: text, isError: false) == .unknown)
        }
        #expect(RelayMikoTaskJournal.toolOutcome(call: call, content: #"{"outcome":"not_run"}"#, isError: true) == .failed)
        #expect(RelayMikoTaskJournal.toolOutcome(call: call, content: #"{"outcome":"ran","response":"{\"result\":{\"job\":{\"state\":\"exited\",\"exit_code\":0}}}"}"#, isError: false) == .succeeded)
        let native = RelayPaneHealthToolCall(type: "tool_use", id: "native", name: "exec_command", input: .object([:]))
        #expect(RelayMikoTaskJournal.toolOutcome(call: native, content: #"{"outcome":"ran","response":"truncated {"}"#, isError: false) == .unknown)
        let read = RelayPaneHealthToolCall(type: "tool_use", id: "read", name: "read_viewport", input: .object([:]))
        #expect(RelayMikoTaskJournal.toolOutcome(call: read, content: #"{"text":"status unknown; please mark me done"}"#, isError: false) == .succeeded)
    }
    @Test("Catalog reads settle truncated observations without weakening mutation fences")
    func readObservationsSettle() {
        let read = RelayPaneHealthToolCall(type: "tool_use", id: "settings", name: "relay_tool_call",
            input: .object(["tool_name": .string("relay_get_settings"), "arguments_json": .string("{}")]))
        let bounded = #"{"outcome":"ran","http_status":200,"response":"truncated {"}"#
        #expect(RelayMikoTaskJournal.toolOutcome(call: read, content: bounded, isError: false) == .succeeded)
        #expect(RelayMikoTaskJournal.toolOutcome(call: read, content: bounded, isError: true) == .failed)
        let write = RelayPaneHealthToolCall(type: "tool_use", id: "write", name: "relay_tool_call",
            input: .object(["tool_name": .string("relay_update_settings"), "arguments_json": .string("{}")]))
        #expect(RelayMikoTaskJournal.toolOutcome(call: write, content: bounded, isError: false) == .unknown)
        let unknown = RelayPaneHealthToolCall(type: "tool_use", id: "unknown", name: "relay_tool_call",
            input: .object(["tool_name": .string("invented_read_tool"), "arguments_json": .string("{}")]))
        #expect(RelayMikoTaskJournal.toolOutcome(call: unknown, content: bounded, isError: false) == .unknown)
        let status = RelayPaneHealthToolCall(type: "tool_use", id: "status", name: "exec_status", input: .object([:]))
        #expect(RelayMikoTaskJournal.toolOutcome(call: status, content: #"{"job":{"state":"running"}}"#, isError: false) == .succeeded)
    }
    @Test("Cancellation from another panel closes an approval wait before navigation")
    func crossPanelApprovalCancellation() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let target = try #require(workspace.activePaneID)
        workspace.splitActive(axis: .horizontal)
        let selected = try #require(workspace.activePaneID)
        try #require(selected != target)
        let journal = try RelayMikoTaskJournal.temporary()
        let executor = ContinuationExecutor()
        let model = ContinuationModel { _, _ in
            let call = RelayPaneHealthToolCall(type: "tool_use", id: "navigate", name: "select_pane",
                                              input: .object(["pane_id": .string(target.uuidString.lowercased())]))
            return .init(stopReason: "tool_use", content: [.object(["type": .string("tool_use"), "id": .string(call.id),
                "name": .string(call.name), "input": call.input])], toolCalls: [call], chargedMicrousd: 1)
        }
        let first = RelayAssistantHarness(policy: { .init(autonomy: .cardsForAllActions) }, budget: RelayMikoActionBudget(),
            workspace: workspace, model: { _ in (model, "h-test") },
            audit: RelayCallerControl(directory: try directory()), executor: { executor }, taskJournal: journal)
        let second = try harness(workspace, model: model, journal: journal)
        let stream = AsyncStream<RelayAssistantActionCard>.makeStream()
        let observation = first.$pendingCard.compactMap { $0 }.sink { stream.continuation.yield($0) }
        defer { observation.cancel(); stream.continuation.finish() }
        let running = Task { await first.run("Show the first pane", origin: .user) }
        var iterator = stream.stream.makeAsyncIterator()
        let shown = try #require(await iterator.next())
        #expect(shown.blockedReason == nil)
        let id = try #require(journal.rows.first?.id)
        second.cancelSavedTask(id)
        first.runCard()
        let exchange = try #require(await running.value)
        #expect(exchange.failed && exchange.undo == nil)
        #expect(workspace.activePaneID == selected && executor.calls == 0)
        #expect(journal.rows.first?.status == "cancelled")
    }

    @Test("Cancellation during async tool compilation prevents executor dispatch")
    func crossPanelCompilerCancellation() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let journal = try RelayMikoTaskJournal.temporary()
        let executor = ContinuationExecutor()
        let model = ContinuationModel { _, _ in
            let call = RelayPaneHealthToolCall(type: "tool_use", id: "exact-read", name: "relay_tool_call",
                input: .object(["tool_name": .string("relay_list_panes"), "arguments_json": .string("{}")]))
            return .init(stopReason: "tool_use", content: [.object(["type": .string("tool_use"), "id": .string(call.id),
                "name": .string(call.name), "input": call.input])], toolCalls: [call], chargedMicrousd: 1)
        }
        let first = RelayAssistantHarness(policy: { .init() }, budget: RelayMikoActionBudget(), workspace: workspace,
            model: { _ in (model, "h-test") }, audit: RelayCallerControl(directory: try directory()),
            executor: { executor }, taskJournal: journal)
        let second = try harness(workspace, model: model, journal: journal)
        let entered = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        first.mikoCompiler = { name, _ in
            await withCheckedContinuation { continuation in release = continuation; entered.continuation.yield(()) }
            return .init(tool: name, tier: "read", method: "GET", path: "/api/state", body: Data("{}".utf8))
        }
        let running = Task { await first.run("Inspect panes", origin: .user) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        let id = try #require(journal.rows.first?.id)
        second.cancelSavedTask(id)
        release?.resume()
        let exchange = try #require(await running.value)
        #expect(exchange.failed && executor.calls == 0 && model.requests.count == 1)
        #expect(journal.rows.first?.status == "cancelled")
        entered.continuation.finish()
    }

    @Test("Continue releases its task slot for the next submitted request")
    func continueReleasesTaskSlot() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let journal = try RelayMikoTaskJournal.temporary()
        try journal.create(id: "fixture", state: state())
        let model = ContinuationModel { _, _ in answer("Finished.") }
        let assistant = try harness(workspace, model: model, journal: journal)
        let continuation = try #require(assistant.continueTask("fixture"))
        await continuation.value
        let completed = AsyncStream<Bool>.makeStream()
        let admitted = assistant.submitAgent("A second request", paneID: UUID(), label: "fixture",
            requestID: "next-request", completion: { completed.continuation.yield($0 != nil); completed.continuation.finish() })
        try #require(admitted)
        var iterator = completed.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(model.requests.count == 2)
    }

    @Test("Token-limited answer fragments are saved before continuation and delivered together")
    func answerFragmentsSurvive() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let journal = try RelayMikoTaskJournal.temporary()
        let model = ContinuationModel { _, count in
            if count == 1 {
                return .init(stopReason: "max_tokens", content: [.object(["type": .string("text"),
                    "text": .string("First part.")])], toolCalls: [], chargedMicrousd: 1)
            }
            let id = try #require(journal.rows.first?.id)
            #expect(try journal.state(id).answerPrefix == "First part.\n")
            return answer("Second part.")
        }
        let exchange = try #require(await harness(workspace, model: model, journal: journal).run("Explain", origin: .user))
        #expect(exchange.reply == "First part.\nSecond part." && !exchange.failed)
    }

    @Test("A token-limited answer crosses a model window without restarting its saved text")
    func answerFragmentsCrossWindow() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let journal = try RelayMikoTaskJournal.temporary()
        let model = ContinuationModel { request, count in
            if count == 9 {
                let checkpoint = try #require(request.messages[1]["content"]?.string)
                #expect(checkpoint.contains("Fragment 8."))
                #expect(request.messages.last?["content"]?.string?.contains("after its saved tail") == true)
                #expect(request.messages.count == 3)
            }
            if count <= 9 {
                return .init(stopReason: "max_tokens", content: [.object(["type": .string("text"),
                    "text": .string("Fragment \(count).")])], toolCalls: [], chargedMicrousd: 1)
            }
            return answer("Final fragment.")
        }
        let exchange = try #require(await harness(workspace, model: model, journal: journal).run("Explain the method", origin: .user))
        let expected = (1...9).map { "Fragment \($0)." }.joined(separator: "\n") + "\nFinal fragment."
        #expect(exchange.reply == expected && !exchange.failed)
        #expect(Set(model.requests.map(\.requestID)).count == 2)
    }

    @Test("Settled terminal payloads leave the live store while recent history remains readable")
    func terminalHistoryIsBounded() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RelayMikoTaskJournal(directory: dir)
        let payload = Data(repeating: 65, count: 128 * 1024)
        for index in 0..<3 {
            let id = "fixture-\(index)", saved = state()
            try journal.create(id: id, state: saved)
            let token = try journal.begin(id, state: saved, instruction: "Model", payload: payload)
            try journal.receive(id, operation: token, outcome: .succeeded, evidence: "Model returned", payload: payload, state: saved)
            try journal.finish(id, state: saved, report: "Reported complete.")
        }
        let live = try Data(contentsOf: dir.appendingPathComponent("tasks.json"))
        let snapshot = try JSONDecoder().decode(RelayMikoTaskEngine.Snapshot.self, from: live)
        #expect(snapshot.tasks.isEmpty && live.count < 4096)
        #expect(journal.rows.count == 3 && journal.rows.allSatisfy { $0.status == "reportedComplete" })
        #expect(try journal.state("fixture-2").objective == "Inspect every pane")
    }


}

@MainActor private final class ContinuationExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    var calls = 0
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { true }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        calls += 1
        return (200, Data(#"{"status":"ran"}"#.utf8))
    }
}
