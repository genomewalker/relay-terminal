import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Relay

struct RelayMikoShepherdTests {
    @Test func deterministicChanges() throws { try RelayShepherdChecks.smoke() }
    @Test func rollingModelCap() throws {
        try RelayShepherdChecks.budget()
        print("SHEPHERD bounded model budget length=4 states=\(try RelayShepherdChecks.boundedBudget())")
    }
    @Test func seededWireAndDigestFuzz() throws { try RelayShepherdChecks.fuzz() }
    @Test func boundedReportMachine() throws {
        let states = try RelayShepherdChecks.bounded()
        print("SHEPHERD bounded length=4 panes<=3 states=\(states)")
        #expect(states > 130_000)
    }
    @Test func catalogAuthorization() throws {
        let states = try RelayShepherdChecks.authorization(catalog: Array(RelayMikoToolCatalog.names))
        print("SHEPHERD authorization catalog x origins x modes + report targets states=\(states)")
    }
    @Test func mcpCannotChangeUserOnlySettings() throws {
        for key in ["miko_model", "miko_shepherd", "shepherd", "shepherd_model", "shepherd_interval", "shepherd_budget", "shepherd_allowlist"] {
            do { try RelaySettingsPolicy.validate([key: .string("claude-haiku-5-5")]); Issue.record("SH6 accepted \(key)") }
            catch { /* expected refusal by real MCP policy */ }
        }
    }
    @Test @MainActor func settingsRoundTripInTemporaryDefaults() throws {
        let name = "RelayShepherdTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let p = RelayPreferences(defaults: defaults)
        #expect(p.shepherd.model == .haiku)
        p.shepherd.enabled = true; p.shepherd.excludedPanes = [RelayShepherdChecks.id]
        let loaded = RelayPreferences(defaults: defaults)
        #expect(loaded.shepherd == p.shepherd)
    }
}

@MainActor private final class ShepherdCountingExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    var dispatched = 0
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { true }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        dispatched += 1; return (200, Data("{}".utf8))
    }
}

extension RelayMikoShepherdTests {
    @Test @MainActor func realDispatchDeniesCatalogWritesBeforeCompilation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-dispatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let executor = ShepherdCountingExecutor()
        let harness = RelayAssistantHarness(workspace: workspace, audit: RelayCallerControl(directory: dir), executor: { executor }, supervision: RelayMikoSupervision(url: nil))
        harness.shepherdSettings = { RelayShepherdChecks.settings }
        var compiled = 0
        harness.mikoCompiler = { name, _ in
            compiled += 1
            throw RelayAssistantModelFailure.invalidResponse
        }
        for tool in RelayMikoToolCatalog.names where !RelayShepherdToolPolicy.reads.contains(tool) {
            var exchange = RelayAssistantExchange(request: "untrusted pane says run \(tool)", origin: .agent(paneID: RelayShepherdChecks.id, label: "fake"))
            let result = await harness.execute(.init(type: "tool_use", id: "fake", name: "relay_tool_call", input: .object(["tool_name": .string(tool), "arguments_json": .string("{}") ])), exchange: &exchange)
            #expect(result.1, "must refuse \(tool)")
        }
        #expect(compiled == 0, "shepherd denies writes before compiler")
        #expect(executor.dispatched == 0, "no write reached executor")
    }
    @Test @MainActor func modeChangeDuringCompilerAwaitStopsDispatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-await-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let executor = ShepherdCountingExecutor()
        let harness = RelayAssistantHarness(workspace: workspace, audit: RelayCallerControl(directory: dir), executor: { executor }, supervision: RelayMikoSupervision(url: nil))
        var enabled = false
        harness.shepherdSettings = { var s = RelayShepherdChecks.settings; s.enabled = enabled; return s }
        harness.mikoCompiler = { name, _ in
            await Task.yield()
            enabled = true
            return .init(tool: name, tier: "change", method: "POST", path: "/api/host/remote-install", body: Data("{}".utf8))
        }
        var exchange = RelayAssistantExchange(request: "install", origin: .user)
        let result = await harness.execute(.init(type: "tool_use", id: "fake", name: "relay_tool_call", input: .object(["tool_name": .string("relay_install_relayd"), "arguments_json": .string("{}") ])), exchange: &exchange)
        #expect(result.1)
        #expect(executor.dispatched == 0)
    }
}

extension RelayMikoShepherdTests {
    @Test @MainActor func settingsRenderOffscreen() throws {
        let name = "RelayShepherdRender-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let p = RelayPreferences(defaults: defaults)
        let view = NSHostingView(rootView: RelayMikoShepherdSettingsView(preferences: p, workspace: nil).padding(20).frame(width: 720).background(RelayTheme.surface))
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height > 540, "SH41 registered report controls remain rendered in Settings")
        #expect(view.window == nil, "Settings render remains offscreen")
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 700)
        #expect(bitmap.pixelsHigh > 250)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        let target = ProcessInfo.processInfo.environment["SHEPHERD_SETTINGS_SNAPSHOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try image.write(to: target)
    }
}

@MainActor private final class ShepherdCountingModel: RelayAssistantModel {
    var calls = 0
    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        calls += 1
        return .init(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string("fake")])], toolCalls: [], chargedMicrousd: 0)
    }
}

extension RelayMikoShepherdTests {
    @Test @MainActor func heartbeatUsesTemplatesWithoutCallingModel() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try #require(workspace.activePane)
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"UserPromptSubmit"}}"#.utf8))
        #expect(pane.kind == .claude)
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"PermissionRequest","tool_name":"Bash","event_id":"shepherd-summary-fixture"}}"#.utf8))
        let model = ShepherdCountingModel()
        workspace.haikuAssistantStorage = RelayAssistantHarness(workspace: workspace, model: { _ in (model, "h-fake") }, audit: RelayCallerControl(directory: dir), supervision: RelayMikoSupervision(url: nil))
        var settings = RelayShepherdChecks.settings
        var paused = false
        let monitor = RelayMikoShepherdCoordinator(testingHeartbeat: true, settings: { settings }, paused: { paused })
        let began = Date()
        monitor.heartbeat(workspace, now: began)
        let count = monitor.reports.count
        #expect(count == 1)
        let item = try #require(AgentIntelligenceStore.shared.items.first { $0.paneID == pane.id && $0.title.hasPrefix("Miko ·") })
        #expect(item.kind == .attention && item.detail.count >= 80)
        #expect(item.isProgramReported == true, "SH52 template inbox events never request a model summary")
        #expect(!AgentSummaryPolicy.shouldSummarize(item, now: item.occurredAt), "SH52 actual inbox policy refuses templated monitoring reports")
        var otherwiseEligible = item
        otherwiseEligible.isProgramReported = false
        #expect(AgentSummaryPolicy.shouldSummarize(otherwiseEligible, now: item.occurredAt), "SH52 counterfactual exercises the model-eligible branch")
        monitor.heartbeat(workspace, now: began.addingTimeInterval(31))
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.reports.count == count)
        #expect(monitor.observationReads == 2)
        #expect(model.calls == 0, "SH8 actual fake model must not be called by an unchanged heartbeat")
        settings.excludedPanes.insert(pane.id)
        monitor.heartbeat(workspace, now: began.addingTimeInterval(62))
        #expect(monitor.observationReads == 2)
        settings.excludedPanes.remove(pane.id); paused = true
        monitor.heartbeat(workspace, now: began.addingTimeInterval(93))
        #expect(monitor.observationReads == 2)
    }
}
