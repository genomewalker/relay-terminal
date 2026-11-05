import AppKit
import Combine
import CryptoKit
import Foundation
import Testing
@testable import Relay

private enum NativeHarnessFailure: Error { case ambiguous }

@MainActor private final class NativeHarnessExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    var grants = Set(MCPWorkspaceCapability.allCases)
    var genericDispatches = 0
    var genericRequests: [(String, String, Data)] = []
    var genericReply = (500, Data())
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { grants.contains(capability) }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        genericDispatches += 1
        genericRequests.append((method, path, body))
        return genericReply
    }
}

@MainActor private final class NativeHarnessFixture {
    let workspace: WorkspaceModel
    let executor = NativeHarnessExecutor()
    let root: URL
    let suite = "dev.relay.native-harness-test." + UUID().uuidString
    let defaults: UserDefaults
    let registry: RelayNativeRegistry
    let directory = RelayAgentAccountDirectory()
    let account = RelayAgentAccount(provider: "codex", label: "work", dir: "")
    let audit: RelayCallerControl
    let supervision = RelayMikoSupervision(url: nil)
    var settings = RelayMikoPolicySettings(autonomy: .cardsForWrites)
    var harness: RelayAssistantHarness!
    var cards: [RelayAssistantActionCard] = []
    var requests: [Data] = []
    var launches: [RelayNativeMikoBridge.PreparedLaunch] = []
    var ambiguous = false
    var wrongReceipt = false
    var onCard: (@MainActor (RelayAssistantActionCard) async -> Void)?
    var callback: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init() throws {
        _ = NSApplication.shared
        workspace = WorkspaceModel(restoreSavedWorkspace: false)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-harness-" + UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suite))
        registry = RelayNativeRegistry(defaults: defaults)
        audit = RelayCallerControl(directory: root)
        let pane = try #require(workspace.activePane)
        try registry.record(.init(identity: .init(pane: pane.id.uuidString.lowercased(),
            instance: UUID().uuidString.lowercased(), provider: "codex"), profile: pane.profile, account: account))
        harness = RelayAssistantHarness(policy: { [unowned self] in self.settings }, budget: RelayMikoActionBudget(),
            workspace: workspace,
            facts: .init(health: { _ in nil }, holdReason: { _ in nil }, rotation: { _ in nil }),
            audit: audit, executor: { [executor] in executor }, supervision: supervision)
        harness.shepherdSettings = { .init() }
        harness.nativeRegistry = registry
        harness.nativeAccountDirectory = directory
        harness.nativeTransport = { [unowned self] binding, body in
            let current = try #require(self.workspace.panes[pane.id])
            #expect(self.registry.binding(for: current) == binding, "NATIVE_TRANSPORT_EXACT_BINDING")
            let mutating = RelayNativeMikoBridge.mutationOperations.contains(body["operation"] as? String ?? "")
            #expect(!mutating || self.executor.permits(.input), "NATIVE_TRANSPORT_INPUT_AUTHORITY")
            let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            if mutating {
                #expect(self.cards.last?.body == encoded, "NATIVE_APPROVED_EXACT_BYTES")
                if let action = body["action"] as? [String: Any] {
                    #expect(action["id"] as? String == self.cards.last?.id.uuidString.lowercased(), "NATIVE_STABLE_ACTION_ID")
                }
            }
            self.requests.append(encoded)
            if self.ambiguous { throw NativeHarnessFailure.ambiguous }
            let operation = body["operation"] as? String
            let action = body["action"] as? [String: Any]
            let receiptID = operation == "receipt" ? body["receiptId"] as? String : action?["id"] as? String
            let receipt = receiptID.map { RelayNativeReceipt(id: self.wrongReceipt ? UUID().uuidString : $0,
                digest: "fixture", state: "sent", detail: nil) }
            return .init(snapshot: operation == "snapshot" ? self.snapshot(binding.identity) : nil,
                receipt: receipt, imagePath: operation == "image" ? "/tmp/fixture-image.png" : nil, error: nil)
        }
        harness.nativeLaunchTransport = { [unowned self] launch, workspace in
            #expect(self.executor.permits(.create) && self.executor.permits(.input), "NATIVE_LAUNCH_BOTH_GRANTS")
            #expect(self.directory.account(for: launch.profile, provider: launch.account.provider,
                label: launch.account.label) == launch.account, "NATIVE_LAUNCH_EXACT_ACCOUNT")
            #expect(workspace.panes[launch.paneID].map(ObjectIdentifier.init) == launch.paneObject, "NATIVE_LAUNCH_EXACT_SOURCE")
            #expect(launch.actionID == self.cards.last?.id, "NATIVE_LAUNCH_STABLE_ID")
            self.launches.append(launch)
            if self.ambiguous { throw NativeHarnessFailure.ambiguous }
        }
        subscription = harness.$pendingCard.sink { [weak self] card in
            guard let self, let card else { return }
            self.callback = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.harness.pendingCard?.id == card.id else { return }
                self.cards.append(card)
                if let onCard = self.onCard { await onCard(card) }
                else if card.blockedReason == nil {
                    self.harness.runCard()
                    self.harness.runCard() // A second user click never reuses approval.
                } else { self.harness.cancelCard() }
            }
        }
    }
    var pane: PaneModel { workspace.activePane! }
    var dispatches: Int { requests.count + launches.count }
    func snapshot(_ identity: RelayNativeIdentity) -> RelayNativeSnapshot {
        .init(version: 1, identity: identity, sessionId: "fixture-session", turnId: "fixture-turn", cwd: "/tmp",
            model: "fixture", phase: "idle", revision: 1, items: [], requests: [],
            capabilities: .init(send: true, steer: true, interrupt: true, interruptScope: "turn", respond: true,
                maintenance: false, scheduledTasks: "unknown", maintenanceReason: "fixture"), failure: nil, olderBefore: nil)
    }
    func call(_ name: String, kind: String = "send", extra: [String: RelayPaneHealthJSON] = [:]) -> RelayPaneHealthToolCall {
        var fields: [String: RelayPaneHealthJSON] = ["pane_id": .string(pane.id.uuidString.lowercased())]
        switch name {
        case "native_receipt": fields["receiptId"] = .string("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        case "native_action":
            let action: String
            switch kind {
            case "steer": action = #"{"kind":"steer","turnId":"fixture-turn","text":"fixture"}"#
            case "interrupt": action = #"{"kind":"interrupt","turnId":"fixture-turn"}"#
            case "respond": action = #"{"kind":"respond","turnId":"fixture-turn","requestId":"fixture-request","decision":"allow"}"#
            default: action = #"{"kind":"send","text":"fixture"}"#
            }
            fields["action_json"] = .string(action)
        case "native_image": fields["imageData"] = .string(Data("image-fixture".utf8).base64EncodedString())
        case "native_launch", "native_resume":
            fields["provider"] = .string(account.provider); fields["account"] = .string(account.label)
        default: break
        }
        fields.merge(extra) { $1 }
        return .init(type: "tool_use", id: UUID().uuidString, name: name, input: .object(fields))
    }
    func execute(_ call: RelayPaneHealthToolCall, paneDerived: Bool = false) async -> (RelayPaneHealthJSON, Bool) {
        var exchange = RelayAssistantExchange(request: "native integration", origin: .user)
        exchange.paneDerived = paneDerived
        let result = await harness.execute(call, exchange: &exchange)
        await callback?.value
        let value = (try? JSONDecoder().decode(RelayPaneHealthJSON.self, from: Data(result.0.utf8))) ?? .null
        return (value, result.1)
    }
    func replaceBinding() throws {
        try registry.record(.init(identity: .init(pane: pane.id.uuidString.lowercased(),
            instance: UUID().uuidString.lowercased(), provider: "codex"), profile: pane.profile, account: account))
    }
    func remapAccount() throws {
        let status = try JSONDecoder().decode(RelayAgentAccountStatus.self, from: Data(
            #"{"provider":"codex","label":"work","dir":"/tmp/remapped-account","root":"/tmp/remapped-account","default":false,"exists":true,"logged_in":"yes"}"#.utf8))
        directory.record([status], executables: nil, fromHost: RelayAgentAccountDirectory.hostKey(pane.profile), probeRequested: false)
    }
    func close() {
        subscription?.cancel(); callback?.cancel(); harness.cancel(); workspace.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Registered native Harness integration", .serialized)
@MainActor struct RelayNativeHarnessIntegrationTests {
    @Test func nativeReadsNeedNoMutationGrant() async throws {
        let f = try NativeHarnessFixture(); defer { f.close() }
        f.executor.grants = []
        for name in ["native_snapshot", "native_receipt"] {
            let result = await f.execute(f.call(name))
            #expect(!result.1 && result.0["outcome"]?.string == "ran", "NATIVE_REGISTERED_READ_WITHOUT_MUTATION_GRANT")
        }
        #expect(f.requests.count == 2 && f.cards.isEmpty && f.executor.genericDispatches == 0)
    }

    @Test func shepherdNativeReadsHonorOptOutAndDenyMutations() async throws {
        let f = try NativeHarnessFixture(); defer { f.close() }
        var shepherd = RelayShepherdSettings()
        shepherd.enabled = true
        f.harness.shepherdSettings = { shepherd }
        f.executor.grants = []
        for name in ["native_snapshot", "native_receipt"] {
            let result = await f.execute(f.call(name))
            #expect(!result.1 && result.0["outcome"]?.string == "ran", "SHEPHERD_NATIVE_REGISTERED_READ")
        }
        #expect(f.requests.count == 2 && f.cards.isEmpty)
        for name in ["native_action", "native_image", "native_launch", "native_resume", "set_capacity_pause", "request_capacity_action"] {
            let result = await f.execute(f.call(name))
            #expect(result.1 && f.dispatches == 2 && f.executor.genericDispatches == 0, "SHEPHERD_NATIVE_MUTATION_REFUSED")
        }
        shepherd.excludedPanes.insert(f.pane.id)
        #expect((await f.execute(f.call("native_snapshot"))).1, "SHEPHERD_NATIVE_PANE_OPT_OUT")
        shepherd.excludedPanes = []
        shepherd.excludedHosts = [f.pane.profile.kind == .local ? "This Mac" : f.pane.profile.host]
        #expect((await f.execute(f.call("native_snapshot"))).1, "SHEPHERD_NATIVE_HOST_OPT_OUT")
        #expect(f.requests.count == 2)
    }

    @Test func nativeMutationsKeepPreparedBytesAndOneApproval() async throws {
        for kind in ["send", "steer", "interrupt", "respond", "image", "launch", "resume"] {
            let f = try NativeHarnessFixture(); defer { f.close() }
            let name = ["image", "launch", "resume"].contains(kind) ? "native_" + kind : "native_action"
            let result = await f.execute(f.call(name, kind: kind))
            #expect(!result.1 && result.0["outcome"]?.string == "ran", "NATIVE_REGISTERED_MUTATION_POSITIVE")
            #expect(f.dispatches == 1 && f.cards.count == 1 && f.executor.genericDispatches == 0, "NATIVE_REGISTERED_SINGLE_DISPATCH")
            let required: [MCPWorkspaceCapability] = ["native_launch", "native_resume"].contains(name) ? [.create, .input] : [.input]
            #expect(f.cards.last?.requiredCapabilities == required, "NATIVE_DECLARED_REQUIRED_GRANTS")
            if let launch = f.launches.first {
                #expect(launch.account == f.account)
                #expect((launch.resume != nil) == (kind == "resume"))
            }
        }
    }

    @Test func registeredNativeToolsRefuseMissingGrantsAndChangedTargets() async throws {
        for name in ["native_action", "native_image", "native_launch", "native_resume"] {
            for grant in name == "native_action" || name == "native_image" ? [MCPWorkspaceCapability.input] : [.input, .create] {
                let f = try NativeHarnessFixture(); defer { f.close() }
                f.executor.grants.remove(grant)
                let result = await f.execute(f.call(name))
                #expect(result.1 && f.dispatches == 0, "NATIVE_REGISTERED_MISSING_GRANT_REFUSAL")
            }
            for change in ["object", "control", "binding", "account"] {
                if change == "binding" && name == "native_launch" { continue }
                if change == "account" && (name == "native_action" || name == "native_image") { continue }
                let f = try NativeHarnessFixture(); defer { f.close() }
                f.onCard = { _ in
                    do {
                        switch change {
                        case "object":
                            let old = f.pane
                            f.workspace.storePane(PaneModel(id: old.id, profile: old.profile))
                        case "control": f.executor.instance = UUID()
                        case "binding": try f.replaceBinding()
                        default: try f.remapAccount()
                        }
                    } catch { Issue.record("native fence fixture failed: \(error)") }
                    f.harness.runCard()
                    f.harness.cancelCard()
                }
                let result = await f.execute(f.call(name))
                #expect(result.1 && f.dispatches == 0, "NATIVE_REGISTERED_CHANGED_TARGET_REFUSAL")
            }
            let f = try NativeHarnessFixture(); defer { f.close() }
            let result = await f.execute(f.call(name), paneDerived: true)
            #expect(result.1 && f.dispatches == 0, "NATIVE_REGISTERED_PANE_ORIGIN_REFUSAL")
        }
    }

    @Test func ambiguousNativeMutationUsesReceiptWithoutReplay() async throws {
        let f = try NativeHarnessFixture(); defer { f.close() }
        f.ambiguous = true
        let result = await f.execute(f.call("native_action"))
        #expect(result.0["outcome"]?.string == "unknown" && f.requests.count == 1, "NATIVE_AMBIGUOUS_NOT_REPLAYED")
        f.harness.runCard(); f.harness.runCard()
        #expect(f.requests.count == 1, "NATIVE_AMBIGUOUS_CARD_CONSUMED")
        f.ambiguous = false
        let id = try #require(result.0["action_id"]?.string)
        let receipt = await f.execute(f.call("native_receipt", extra: ["receiptId": .string(id)]))
        #expect(!receipt.1 && receipt.0["outcome"]?.string == "ran" && f.requests.count == 2, "NATIVE_RECEIPT_READBACK")
        f.wrongReceipt = true
        let wrong = await f.execute(f.call("native_receipt"))
        #expect(wrong.1, "NATIVE_RECEIPT_ID_MUST_MATCH")
    }

    @Test func nativeSchemaFuzzRetainsIdentityAndBounds() throws {
        let f = try NativeHarnessFixture(); defer { f.close() }
        let snapshot = RelayAssistantSnapshot.capture(f.workspace)
        var random: UInt64 = 0x4e415449564548
        for index in 0..<4096 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let name = ["native_action", "native_snapshot", "native_receipt", "native_image"][index % 4]
            var call = f.call(name)
            if index % 3 == 0 {
                guard case .object(var fields) = call.input else { throw NativeHarnessFailure.ambiguous }
                fields[index % 2 == 0 ? "identity" : "action_id"] = .string(String(random))
                call = .init(type: call.type, id: call.id, name: call.name, input: .object(fields))
                if case .success = RelayAssistantToolValidator.validate(name: name, input: call.input, snapshot: snapshot) {
                    Issue.record("NATIVE_SCHEMA_CALLER_IDENTITY_ACCEPTED")
                }
            } else {
                let encoded = try RelayPaneHealthJSON.data(call.input)
                #expect(try JSONDecoder().decode(RelayPaneHealthJSON.self, from: encoded) == call.input, "NATIVE_SCHEMA_ROUNDTRIP")
                #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(RelayPaneHealthJSON.self, from: encoded.dropLast()) }
                guard case .success(.change(let change)) = RelayAssistantToolValidator.validate(name: name, input: call.input, snapshot: snapshot) else {
                    Issue.record("NATIVE_SCHEMA_VALID_REQUEST_REFUSED"); continue
                }
                let prepared = try RelayNativeMikoBridge.prepare(pane: f.pane, body: Data((change.text ?? "").utf8),
                    actionID: UUID(), executor: f.executor, registry: f.registry)
                #expect(prepared.binding == f.registry.binding(for: f.pane), "NATIVE_SCHEMA_BOUND_IDENTITY")
            }
        }
        print("Native registered schema seed=0x4e415449564548 samples=4096; exact identity, round trip, truncated object rejection")
    }

    @Test func nativeLaunchRechecksAuthorityAfterCapabilityAwait() async throws {
        for name in ["native_launch", "native_resume"] {
            do {
                let f = try NativeHarnessFixture(); defer { f.close() }
                let before = f.workspace.tabs.count
                f.harness.nativeLaunchTransport = nil
                f.harness.nativeCapabilityProbe = { _ in throw NativeHarnessFailure.ambiguous }
                let result = await f.execute(f.call(name))
                #expect(result.0["outcome"]?.string == "refused" && f.workspace.tabs.count == before,
                        "NATIVE_PROBE_FAILURE_NOT_SUBMITTED")
            }
            for change in ["input", "create", "control", "object", "account", "binding"] {
                if name == "native_launch" && change == "binding" { continue }
                let f = try NativeHarnessFixture(); defer { f.close() }
                let tabs = f.workspace.tabs.count
                var probes = 0
                f.harness.nativeLaunchTransport = nil
                f.harness.nativeCapabilityProbe = { _ in
                    probes += 1
                    await Task.yield()
                    switch change {
                    case "input": f.executor.grants.remove(.input)
                    case "create": f.executor.grants.remove(.create)
                    case "control": f.executor.instance = UUID()
                    case "object": f.workspace.storePane(PaneModel(id: f.pane.id, profile: f.pane.profile))
                    case "account": try f.remapAccount()
                    default: try f.replaceBinding()
                    }
                }
                let result = await f.execute(f.call(name))
                #expect(probes == 1 && f.workspace.tabs.count == tabs && result.0["outcome"]?.string == "refused",
                    "NATIVE_LAUNCH_POST_PROBE_REVALIDATION")
                #expect(f.dispatches == 0 && f.executor.genericDispatches == 0)
            }
        }
        let f = try NativeHarnessFixture(); defer { f.close() }
        let before = f.workspace.tabs.count
        var submissions = 0
        #expect(await f.workspace.openTab(running: "fixture", profile: f.pane.profile, besidePane: f.pane.id,
            authorization: { false }, onSubmit: { submissions += 1 }) == nil, "NATIVE_TAB_CREATE_AUTHORITY")
        #expect(f.workspace.tabs.count == before && submissions == 0, "NATIVE_DENIED_LAUNCH_CREATED_TAB")
        var checks = 0
        #expect(await f.workspace.openTab(running: "fixture", profile: f.pane.profile, besidePane: f.pane.id,
            authorization: { checks += 1; return checks == 1 }, onSubmit: { submissions += 1 }) == nil, "NATIVE_TAB_WAIT_AUTHORITY")
        #expect(checks == 2 && f.workspace.tabs.count == before + 1 && submissions == 1, "NATIVE_TAB_WAIT_KEEPS_BLANK_TAB_WITHOUT_INPUT")
    }

    @Test func nativeShellInputRechecksAuthorityAfterOwnerAwait() async throws {
        for initiallyAuthorized in [false, true] {
            for change in ["unchanged", "authority", "input", "prompt", "owner", "unknown", "connection"] {
                let pane = PaneModel(profile: .sshConfigHost("native-shell-fixture.invalid"))
                pane.connectionState = .connected
                let runtime = pane.runtime
                defer { pane.stopRuntime() }
                var authorized = initiallyAuthorized, empty = true, reads = 0, writes = 0
                let shell = RelayPromptOwnerIdentity(hostID: pane.profile.id,
                    binding: .init(version: 1, paneId: pane.id.uuidString.lowercased(), nodeBootId: "fixture",
                        workerPid: 42, workerStart: 1, shellPid: 43, shellStart: 2,
                        provider: "shell", processId: 43, processStart: 2, sessionId: nil, transcriptIdentity: nil))
                let transport = TerminalRuntime.AssistantShellTransport(promptIsEmpty: { empty }, readOwner: {
                    reads += 1
                    await Task.yield()
                    switch change {
                    case "authority": authorized = false
                    case "input": pane.userEnteredInput()
                    case "prompt": empty = false
                    case "connection": pane.connectionState = .disconnected("fixture")
                    case "owner": return .init(hostID: UUID(), binding: shell.binding)
                    case "unknown": return nil
                    default: break
                    }
                    return shell
                }, send: { text, limit in
                    writes += 1
                    #expect(text == "fixture command" && limit == 16 << 10, "NATIVE_SHELL_EXACT_FINAL_WRITE")
                    return true
                })
                let accepted = await runtime.sendAssistantShellCommand("fixture command", authorization: { authorized },
                    transport: transport)
                let expected = initiallyAuthorized && change == "unchanged"
                #expect(reads == (initiallyAuthorized ? 1 : 0), "NATIVE_SHELL_AUTHORITY_BEFORE_OWNER_READ")
                #expect(accepted == expected && writes == (expected ? 1 : 0), "NATIVE_SHELL_AUTHORITY_AFTER_OWNER_AWAIT")
            }
        }
        print("Native shell actual runtime: initial authority2 x owner-await events7 =14 cases; final observation/write transport is a fixture")
    }

    @Test func capacityToolsRetainExplicitSchemaAndActualHarnessAuthority() async throws {
        let forms: [(String, [String: RelayPaneHealthJSON], String)] = [
            ("set_capacity_pause", ["paused": .bool(true)], "pause"),
            ("set_capacity_pause", ["paused": .bool(false)], "resume"),
            ("request_capacity_action", ["action": .string("manual_refresh")], "manual_refresh"),
            ("request_capacity_action", ["action": .string("manual_move"), "target_account": .string("work")], "manual_move"),
        ]
        for (name, fields, action) in forms {
            for granted in [false, true] { for paneOrigin in [false, true] {
                let f = try NativeHarnessFixture(); defer { f.close() }
                f.executor.genericReply = (200, Data(#"{"status":"applied"}"#.utf8))
                if !granted { f.executor.grants.remove(.input) }
                let result = await f.execute(f.call(name, extra: fields), paneDerived: paneOrigin)
                let admitted = granted && !paneOrigin
                #expect((f.executor.genericDispatches == 1) == admitted, "CAPACITY_REGISTERED_INPUT_AND_ORIGIN_AUTHORITY")
                #expect(result.1 != admitted)
                #expect(RelayMikoActionPolicy.tier(name) == .coordination, "CAPACITY_REGISTERED_COORDINATION_TIER")
                if admitted {
                    let request = try #require(f.executor.genericRequests.first)
                    #expect(request.0 == "POST" && request.1 == "/api/panes/" + f.pane.id.uuidString.lowercased() + "/capacity-action",
                        "CAPACITY_REGISTERED_NATIVE_ROUTE")
                    #expect(request.2 == f.cards.last?.body, "CAPACITY_REGISTERED_EXACT_APPROVED_BYTES")
                    #expect(try RelayCapacityActionRequest.decode(request.2).action == action, "CAPACITY_REGISTERED_TYPED_BODY")
                }
            }}
        }
        let f = try NativeHarnessFixture(); defer { f.close() }
        let snapshot = RelayAssistantSnapshot.capture(f.workspace)
        for (name, fields) in [
            ("set_capacity_pause", ["paused": RelayPaneHealthJSON.string("true")]),
            ("request_capacity_action", ["action": .string("stop_tasks")]),
            ("request_capacity_action", ["action": .string("manual_move")]),
            ("request_capacity_action", ["action": .string("manual_move"), "target_account": .string("../outside")]),
            ("request_capacity_action", ["action": .string("manual_refresh"), "target_account": .string("work")]),
            ("set_capacity_pause", ["paused": .bool(true), "capabilities": .string("retire")]),
            ("set_capacity_pause", ["paused": .bool(true), "source": .string("invented-lease")]),
        ] {
            let call = f.call(name, extra: fields)
            if case .success = RelayAssistantToolValidator.validate(name: name, input: call.input, snapshot: snapshot) {
                Issue.record("CAPACITY_REGISTERED_SCHEMA_ESCALATION")
            }
        }
    }

    @Test func nativeApprovalEveryTwoActorSequenceThroughDepthThree() async throws {
        var sequences = 0, steps = 0
        var states: Set<String> = []
        // Owner: Run/Cancel. Other actor: revoke input/create, replace native
        // binding or replace control. All six-event sequences through depth 3
        // are prefixes of these 216 sequences, for each registered mutation.
        for name in ["native_action", "native_image", "native_launch", "native_resume"] {
            for encoded in 0..<216 {
                let f = try NativeHarnessFixture(); defer { f.close() }
                let initialControl = f.executor.instance
                let initialBinding = f.registry.binding(for: f.pane)
                f.onCard = { _ in
                    var sequence = encoded
                    for _ in 0..<3 {
                        let operation = sequence % 6; sequence /= 6
                        switch operation {
                        case 0: f.harness.runCard()
                        case 1: f.harness.cancelCard()
                        case 2: f.executor.grants.remove(.input)
                        case 3: f.executor.grants.remove(.create)
                        case 4:
                            do { try f.replaceBinding() } catch { Issue.record("native bounded fixture: \(error)") }
                        default: f.executor.instance = UUID()
                        }
                        await Task.yield()
                        #expect(f.dispatches <= 1, "NATIVE_BOUNDED_SINGLE_DISPATCH")
                        #expect(f.executor.genericDispatches == 0, "NATIVE_BOUNDED_NO_GENERIC_BYPASS")
                        states.insert("\(name):\(f.harness.pendingCard != nil):\(f.executor.permits(.input)):\(f.executor.permits(.create)):\(f.executor.instance == initialControl):\(f.registry.binding(for: f.pane) == initialBinding):\(f.dispatches)")
                        steps += 1
                    }
                    f.harness.cancelCard()
                }
                _ = await f.execute(f.call(name))
                #expect(f.dispatches <= 1, "NATIVE_BOUNDED_FINAL_SINGLE_DISPATCH")
                try #require(f.dispatches <= 1, "NATIVE_BOUNDED_FINAL_SINGLE_DISPATCH")
                sequences += 1
            }
        }
        #expect(sequences == 864 && steps == 2592)
        print("Native registered actual Harness: alphabet6 depth3 actors2 tools4 sequences=\(sequences) transitions=\(steps) observedStates=\(states.count); trust fixture transport and main-actor scheduler")
    }
}
