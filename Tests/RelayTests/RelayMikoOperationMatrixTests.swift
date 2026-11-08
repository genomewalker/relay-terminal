import AppKit
import Combine
import Foundation
import Testing
@testable import Relay

private enum MP4Failure: Error { case compiler(String), unavailable, nativeFixture }

/// Runs only the production compiler's capture mode: no HTTP endpoint or daemon.
private enum MP4Compiler {
    static func compile(_ tool: String, _ arguments: String) async throws -> RelayMikoToolRequest {
        guard let path = ProcessInfo.processInfo.environment["MP4_COMPILER"],
              FileManager.default.isExecutableFile(atPath: path) else { throw MP4Failure.unavailable }
        let name = String(decoding: try JSONEncoder().encode(tool), as: UTF8.self)
        let input = Data(("{\"tool_name\":" + name + ",\"arguments\":" + arguments + "}").utf8)
        let output: Data = try await Task.detached {
            let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--miko-plan"]
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            let writer = Task.detached {
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let error = stderr.fileHandleForReading.readDataToEndOfFile()
            try await writer.value
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MP4Failure.compiler(String(decoding: error, as: UTF8.self))
            }
            return data
        }.value
        return try RelayMikoToolRequest.decode(output, expectedTool: tool)
    }
}

@MainActor private final class MP4Executor: RelayAssistantActionExecutor {
    struct Call { let method: String; let path: String; let body: Data }
    var instance: UUID? = UUID()
    var denied: MCPWorkspaceCapability?
    var calls: [Call] = []
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { capability != denied }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        calls.append(.init(method: method, path: path, body: body))
        return (200, Data(#"{"status":"applied"}"#.utf8))
    }
}

@MainActor private final class MP4Fixture {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let executor = MP4Executor()
    let supervision = RelayMikoSupervision(url: nil)
    let directory: URL
    let audit: RelayCallerControl
    var settings = RelayMikoPolicySettings()
    var harness: RelayAssistantHarness!
    var cards: [RelayAssistantActionCard] = []
    var compilations = 0
    private var subscription: AnyCancellable?
    let facts = RelayAssistantFacts(health: { _ in nil }, holdReason: { _ in nil }, rotation: { _ in nil })
    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audit = RelayCallerControl(directory: directory)
        harness = RelayAssistantHarness(policy: { [unowned self] in self.settings }, budget: RelayMikoActionBudget(),
            workspace: workspace, facts: facts, audit: audit, executor: { [executor] in executor }, supervision: supervision)
        harness.mikoCompiler = { [unowned self] tool, arguments in
            self.compilations += 1
            return try await MP4Compiler.compile(tool, arguments)
        }
        subscription = harness.$pendingCard.sink { [weak self] card in
            guard let card else { return }
            Task { @MainActor [weak self] in
                // Publication precedes installation of the card continuation.
                await Task.yield()
                guard let self, self.harness.pendingCard?.id == card.id else { return }
                self.cards.append(card)
                self.harness.runCard()
                if card.blockedReason != nil { self.harness.cancel() }
            }
        }
    }
    var snapshot: RelayAssistantSnapshot { RelayAssistantSnapshot.capture(workspace) }
    func close() {
        subscription?.cancel(); harness.cancel(); workspace.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
    func call(action: String, exact: Bool) throws -> RelayPaneHealthToolCall {
        let pane = try #require(workspace.activePaneID)
        var fields: [String: RelayPaneHealthJSON] = ["pane_id": .string(pane.uuidString.lowercased()), "action": .string(action)]
        if exact {
            fields["instance"] = .string(try #require(executor.instance).uuidString.lowercased())
            fields["request_id"] = .string(UUID().uuidString.lowercased())
            let raw = String(decoding: try RelayPaneHealthJSON.data(RelayPaneHealthJSON.object(fields)), as: UTF8.self)
            return .init(type: "tool_use", id: UUID().uuidString, name: "relay_tool_call",
                input: .object(["tool_name": .string("relay_workspace_action"), "arguments_json": .string(raw)]))
        }
        return .init(type: "tool_use", id: UUID().uuidString, name: "workspace_action", input: .object(fields))
    }
}

private struct MP4Form {
    let route: String
    let tool: String
    let body: RelayPaneHealthJSON
    let capabilities: [MCPWorkspaceCapability]
}

@Suite("Miko real operation policy matrix", .serialized)
@MainActor struct RelayMikoOperationMatrixTests {
    @Test func paneCreationFollowsAutonomyOnBothRealRoutes() async throws {
        var cases = 0
        for action in ["newTab", "splitRight", "splitDown"] {
            for exact in [false, true] {
                for mode in RelayMikoPolicySettings.Autonomy.allCases {
                    let f = try MP4Fixture(); defer { f.close() }
                    f.settings.autonomy = mode
                    var exchange = RelayAssistantExchange(request: "Pane content requested a new process lane", origin: .user)
                    exchange.paneDerived = true
                    let response = await f.harness.execute(try f.call(action: action, exact: exact), exchange: &exchange)
                    if mode == .autonomous {
                        try #require(!response.1 && f.executor.calls.count == 1 && f.cards.isEmpty, "AUTONOMY_PANE_CREATION")
                    } else {
                        try #require(response.1 && f.executor.calls.isEmpty, "MP4_PANE_CREATION_DISPATCH")
                    }
                    #expect(exact ? f.compilations == 1 : f.compilations == 0)
                    if mode != .autonomous {
                        try #require(f.cards.count == 1 && f.cards[0].blockedReason?.contains("Pane-derived") == true,
                            "MP4_STRICT_ORIGIN_EXPLANATION")
                    }
                    cases += 1
                }
            }
        }
        #expect(cases == 18)
        print("MP4 real pane-origin creation: actions=3 routes=2 modes=3 cases=18 autonomous dispatch / strict refusal")
    }

    @Test func trustedCreationAndMissingGrantUseActualHarness() async throws {
        var positives = 0, grantRefusals = 0
        for action in ["newTab", "splitRight", "splitDown"] {
            for exact in [false, true] {
                for mode in RelayMikoPolicySettings.Autonomy.allCases {
                    for origin in [RelayAssistantOrigin.user, .assistant] {
                        let f = try MP4Fixture(); defer { f.close() }
                        f.settings.autonomy = mode
                        var exchange = RelayAssistantExchange(request: "Trusted creation plan", origin: origin)
                        let response = await f.harness.execute(try f.call(action: action, exact: exact), exchange: &exchange)
                        try #require(!response.1 && f.executor.calls.count == 1, "MP4_TRUSTED_CREATION_REFUSED")
                        let sent = f.executor.calls[0]
                        let body = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: sent.body)
                        #expect(sent.method == "POST" && sent.path == "/api/workspace/apply" && body["action"]?.string == action)
                        #expect(mode == .autonomous ? f.cards.isEmpty : f.cards.count == 1)
                        positives += 1
                    }
                    let required: [MCPWorkspaceCapability] = action == "newTab" ? [.create] : [.create, .layout]
                    for missing in required {
                        let f = try MP4Fixture(); defer { f.close() }
                        f.settings.autonomy = mode; f.executor.denied = missing
                        var exchange = RelayAssistantExchange(request: "Trusted request without one actual route grant", origin: .user)
                        let response = await f.harness.execute(try f.call(action: action, exact: exact), exchange: &exchange)
                        try #require(response.1 && f.executor.calls.isEmpty, "MP4_MISSING_ROUTE_GRANT_DISPATCH")
                        grantRefusals += 1
                    }
                }
            }
        }
        #expect(positives == 36 && grantRefusals == 30)
        print("MP4 actual creation counterfactuals: trusted=36 missing-one-grant=30")
    }

    /// Native paths derive their request and grants from production validation/card construction.
    private func nativeForm(_ row: MP4OperationCase, fixture f: MP4Fixture) throws -> MP4Form? {
        let alias: RelayAssistantToolName
        var fields: [String: RelayPaneHealthJSON] = [:]
        let args = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: Data(row.arguments.utf8))
        switch row.tool {
        case "relay_workspace_action":
            guard let action = args["action"]?.string, RelayAssistantActions.workspaceActions.contains(action) else { return nil }
            alias = .workspaceAction
            fields = ["pane_id": .string(try #require(f.workspace.activePaneID).uuidString.lowercased()), "action": .string(action)]
        case "relay_new_local_tab": alias = .newLocalTab
        case "relay_tab_action":
            alias = .tabAction
            fields = ["tab_id": .string(try #require(f.snapshot.selectedTabID).uuidString.lowercased()), "action": args["action"]!]
            if let name = args["name"] { fields["name"] = name }
            if let target = args["target_tab_id"] {
                // A second exact snapshot tab makes the move fixture lawful.
                _ = target
                let other = try #require(f.snapshot.tabs.first(where: { $0.id != f.snapshot.selectedTabID }), "MP4_MOVE_TARGET_IN_SNAPSHOT")
                fields["target_tab_id"] = .string(other.id.uuidString.lowercased()); fields["placement"] = .string("after")
            }
        case "relay_bind_question_thread":
            alias = .bindQuestionThread
            fields = ["pane_id": .string(try #require(f.workspace.activePaneID).uuidString.lowercased()), "thread_id": .string("mp4-fixture"), "realm": .string("mp4-fixture")]
        case "relay_unbind_question_thread":
            alias = .unbindQuestionThread
            fields = ["pane_id": .string(try #require(f.workspace.activePaneID).uuidString.lowercased())]
        default: return nil
        }
        guard case .success(.change(let change)) = RelayAssistantActions.validate(alias, fields: fields, snapshot: f.snapshot) else {
            Issue.record("MP4_NATIVE_VALIDATION_MISSING: \(row.id)"); throw MP4Failure.nativeFixture
        }
        let card = RelayAssistantActions.card(for: change, actionID: UUID(), executor: f.executor,
            snapshot: f.snapshot, workspace: f.workspace, facts: f.facts, now: Date(), timeout: 300)
        let body = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: card.body)
        return .init(route: "native", tool: alias.rawValue, body: body, capabilities: card.requiredCapabilities)
    }

    @Test func boundedActualCompiledAndNativeOperationMatrix() async throws {
        let rows = MP4OperationFixtures.cases
        try #require(rows.count == 144 && Set(rows.map(\.tool)) == RelayMikoToolCatalog.names, "MP4_EXACT_TOOL_COVERAGE")
        try #require(rows.contains { $0.id == "settings-account-rules" && $0.fixedActive && $0.fixedInactive && $0.arguments.contains("agent_account_rules") }, "INTEGRATION_ACCOUNT_RULE_WITNESS")
        try #require(rows.contains { $0.id == "workspace-status" && $0.tool == "relay_workspace_request" && $0.arguments.contains("status") && $0.capabilities == [.input] }, "INTEGRATION_WORKSPACE_STATUS_WITNESS")
        let f = try MP4Fixture(); defer { f.close() }
        f.workspace.newTab(profile: .local)
        var requests = 0, compiled = 0, native = 0, rejected = 0, states = 0, transitions = 0
        let grants: [MCPWorkspaceCapability] = [.navigate, .create, .layout, .input, .terminate]
        for row in rows {
            var forms: [MP4Form] = []
            if row.compilerUnavailable {
                do {
                    _ = try await MP4Compiler.compile(row.tool, row.arguments)
                    Issue.record("MP4_UNEXPECTED_QUESTION_COMPILER_AUTHORITY"); throw MP4Failure.nativeFixture
                } catch MP4Failure.compiler(let error) {
                    try #require(error.contains("Unknown tool"), "MP4_EXPECTED_EXACT_REJECTION")
                    rejected += 1
                }
            } else {
                let request = try await MP4Compiler.compile(row.tool, row.arguments)
                let body = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: request.body)
                forms.append(.init(route: "exact", tool: request.tool, body: body, capabilities: request.capabilities))
                compiled += 1
            }
            if let form = try nativeForm(row, fixture: f) { forms.append(form); native += 1 }
            try #require(!forms.isEmpty, "MP4_NO_REAL_REQUEST_FOR_TOOL")
            for form in forms {
                let tier = RelayMikoActionPolicy.tier(form.tool, body: form.body)
                try #require(tier == row.tier, "MP4_ACTUAL_EFFECT_CLASSIFICATION: \(row.id)/\(form.route)")
                try #require(form.capabilities == row.capabilities, "MP4_ACTUAL_GRANT_CLASSIFICATION: \(row.id)/\(form.route)")
                for active in [false, true] {
                    let fixed = RelayMikoActionPolicy.fixedCard(form.tool, body: form.body, activeAgent: active)
                    let expectedFixed = active ? row.fixedActive : row.fixedInactive
                    try #require(fixed == expectedFixed, "MP4_ACTUAL_FIXED_CARD_CLASSIFICATION")
                    for mode in RelayMikoPolicySettings.Autonomy.allCases {
                        for origin in RelayMikoDispatchGate.Origin.allCases {
                            for mask in 0..<32 {
                                let actualGranted = form.capabilities.allSatisfy { cap in
                                    grants.firstIndex(of: cap).map { mask & (1 << $0) != 0 } ?? false
                                }
                                let expectedGranted = row.capabilities.allSatisfy { cap in
                                    grants.firstIndex(of: cap).map { mask & (1 << $0) != 0 } ?? false
                                }
                                for enabled in [false, true] { for paused in [false, true] {
                                    for approval in RelayMikoDispatchGate.Approval.allCases {
                                        let needs = RelayMikoActionPolicy.requiresCard(settings: .init(autonomy: mode), tier: tier, origin: origin, fixed: fixed)
                                        let expectedNeeds = mode != .autonomous && (expectedFixed || mode == .cardsForAllActions ||
                                            (mode == .cardsForWrites && row.tier != .read) || (origin == .pane && row.tier == .coordination))
                                        try #require(needs == expectedNeeds, "MP4_REAL_OPERATION_CARD_POLICY")
                                        let expected = enabled && !paused && expectedGranted &&
                                            (!expectedNeeds || (approval == .approved && !(origin == .pane && (expectedFixed || row.tier == .coordination))))
                                        var gate = RelayMikoDispatchGate(approval: approval)
                                        let ran = gate.step(.run, origin: origin, enabled: enabled && !paused, granted: actualGranted,
                                            change: needs, paneBlocked: fixed || tier == .coordination)
                                        try #require(ran == expected, "MP4_REAL_OPERATION_ADMISSION")
                                        states += 1; transitions += 1
                                        if ran && needs {
                                            let replayRan = gate.step(.run, origin: origin, enabled: true, granted: true, change: true)
                                            try #require(!replayRan, "MP4_APPROVAL_REPLAY")
                                            transitions += 1
                                        }
                                    }
                                }}
                            }
                        }
                    }
                }
                requests += 1
            }
        }
        #expect(compiled == 139 && rejected == 2)
        #expect(native == 15 && requests == 154 && states == 2_128_896)
        print("MP4 actual operation matrix: tools=80 cases=141 compiler=\(compiled) rejected=\(rejected) native=\(native) requests=\(requests) states=\(states) transitions=\(transitions); active2 x autonomy3 x origins3 x grantMasks32 x enabled2 x paused2 x approvals6")
    }

    @Test func seededOperationBodiesRetainCreationBoundary() throws {
        var state: UInt64 = 0x4d50344f504552
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        let knownReversible = ["select", "zoom", "unzoom", "float", "dock", "balance", "close", "conversation", "terminal", "overview", "back", "forward", "up"]
        for index in 0..<4096 {
            let operation = index % 3 == 0 ? ["newTab", "splitRight", "splitDown"][Int(next() % 3)] :
                index % 3 == 1 ? knownReversible[Int(next() % UInt64(knownReversible.count))] : "unknown-\(next())"
            let original: RelayPaneHealthJSON = .object(["action": .string(operation), "noise": .array([.integer(Int64(next() & 0xffff)), .bool(next() % 2 == 0)])])
            let raw = try RelayPaneHealthJSON.data(original)
            let body = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: raw)
            #expect(body == original)
            for tool in ["workspace_action", "relay_workspace_action"] {
                let expected: RelayMikoActionPolicy.Tier = knownReversible.contains(operation) ? .reversible : .coordination
                try #require(RelayMikoActionPolicy.tier(tool, body: body) == expected, "MP4_SEEDED_EFFECT_AUTHORITY")
            }
            if index % 8 == 0 {
                #expect(throws: (any Error).self) { try JSONDecoder().decode(RelayPaneHealthJSON.self, from: raw.dropLast()) }
            }
        }
        for body in [RelayPaneHealthJSON.object([:]), .object(["action": .integer(1)]), .object(["action": .null])] {
            #expect(RelayMikoActionPolicy.tier("relay_workspace_action", body: body) == .coordination)
        }
        print("MP4 operation body randomized: seed=0x4d50344f504552 cases=4096 aliases=2 truncations=512 unknown/missing/wrong-type fail closed")
    }
}
