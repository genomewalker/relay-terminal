import Foundation
import Testing
@testable import Relay

/// Items 8 and 9 (0.5.113): paused update restarts and protected panes hold
/// automatic restarts with a reason code; every automatic restart step is
/// caller-audited as "agent-maintenance"; recentActions drops nothing silently.
@Suite("Agent maintenance update holds")
struct RelayMaintenanceUpdateHoldTests {
    private static let pane = UUID(uuidString: "767dc718-0000-4000-8000-000000000001")!

    @Test func aProtectedPaneIsNeverRestartedAutomatically() {
        let protected = [Self.pane.uuidString.lowercased()]
        for reason in [RelayAgentMaintenancePolicy.Reason.update, .binding] {
            let hold = RelayAgentMaintenancePolicy.automaticRestartHold(reason: reason, paneID: Self.pane, paused: false,
                protected: protected, transition: "2.1.1 → 2.1.2")
            #expect(hold?.code == .protectedPane)
            #expect(hold?.code.rawValue == "protected")
        }
        #expect(RelayAgentMaintenancePolicy.automaticRestartHold(reason: .update, paneID: Self.pane, paused: false,
            protected: protected, transition: "2.1.1 → 2.1.2")?.blocker == "Update 2.1.1 → 2.1.2 available, held: protected")
        #expect(RelayAgentMaintenancePolicy.automaticRestartHold(reason: .update, paneID: UUID(), paused: false,
            protected: protected, transition: nil) == nil)
    }

    @Test func pausedUpdateRestartsHoldUpdatesOnly() {
        let update = RelayAgentMaintenancePolicy.automaticRestartHold(reason: .update, paneID: Self.pane, paused: true,
            protected: [], transition: "0.169.0 → 0.170.0")
        #expect(update?.code == .updatesPaused)
        #expect(update?.blocker == "Update 0.169.0 → 0.170.0 available, held: update restarts are paused")
        #expect(RelayAgentMaintenancePolicy.automaticRestartHold(reason: .binding, paneID: Self.pane, paused: true,
            protected: [], transition: nil) == nil)
        #expect(RelayAgentMaintenancePolicy.automaticRestartHold(reason: .update, paneID: Self.pane, paused: false,
            protected: [], transition: nil) == nil)
    }

    @Test func theProtectedSettingIsExactlyAListOfPaneUUIDs() throws {
        let upper = Self.pane.uuidString
        #expect(try RelayAgentMaintenancePolicy.protectedPanes(Data(#"{"panes":["\#(upper)","\#(upper)"]}"#.utf8)) ==
            [upper.lowercased()])
        for bad in [#"{"panes":["not-a-uuid"]}"#, #"{"panes":[],"extra":1}"#, #"{"ids":[]}"#, #"[]"#] {
            #expect(throws: (any Error).self) { try RelayAgentMaintenancePolicy.protectedPanes(Data(bad.utf8)) }
        }
        #expect(RelayAgentMaintenancePolicy.validProtectedPanes(Array(repeating: upper, count: 257)) == nil)
    }

    @Test func bothSettingsAreInTheSchemaAndMikoCannotChangeThem() throws {
        let keys = RelaySettingsPolicy.definitions.map(\.key)
        #expect(keys.contains("agent_update_restarts_paused") && keys.contains("agent_maintenance_protected_panes"))
        try RelaySettingsPolicy.validate(["agent_update_restarts_paused": .bool(true)])
        try RelaySettingsPolicy.validate(["agent_maintenance_protected_panes":
            .json(.object(["panes": .array([.string(Self.pane.uuidString.lowercased())])]))])
        #expect(throws: (any Error).self) {
            try RelaySettingsPolicy.validate(["agent_maintenance_protected_panes": .json(.object(["panes": .array([.string("x")])]))])
        }
        #expect(!RelaySettingsPolicy.allows(changes: ["agent_update_restarts_paused": .bool(false)], assistantIdentity: true))
        #expect(!RelaySettingsPolicy.allows(changes: ["agent_maintenance_protected_panes": .json(.object(["panes": .array([])]))],
                                            assistantIdentity: true))
        #expect(RelaySettingsPolicy.allows(changes: ["agent_update_restarts_paused": .bool(true)], assistantIdentity: false))
    }

    @MainActor @Test func anAutomaticRestartStepIsAuditedAsAgentMaintenance() {
        let record = RelayAgentMaintenance.auditRecord(action: "abc", paneID: Self.pane, reason: .update,
                                                       outcome: "admitted", detail: "0.169.0 → 0.170.0")
        #expect(record.caller == "agent-maintenance" && record.caller == RelayCallerControl.maintenanceCaller)
        #expect(record.operation == "agent_maintenance.update_restart")
        #expect(record.requestID == "abc" && record.paneID == Self.pane.uuidString.lowercased())
        #expect(record.outcome == "admitted" && record.preview == "0.169.0 → 0.170.0")
    }

    @MainActor @Test func recentActionsKeepEveryEntryOfTheLastDayAndCountTheRest() {
        let now = Date()
        func entry(_ i: Int, age: TimeInterval, state: String = "verified") -> RelayAgentMaintenanceJournal.Entry {
            .init(id: String(format: "%064d", i), paneID: UUID(), host: "dandy-07", reason: .update, sessionID: "s\(i)",
                  createdAt: now.addingTimeInterval(-age), state: state, modelOperationID: nil, modelToolID: nil,
                  resumeCommand: nil, originalOwner: nil, originalProcessID: nil, originalProcessStart: nil)
        }
        // 17 update restarts in one morning (the 0.170.0 rollout): the 17th,
        // af242052's, is kept.
        let morning = (0..<17).map { entry($0, age: TimeInterval($0) * 60) }
        let old = (17..<40).map { entry($0, age: 3 * 86_400 + TimeInterval($0)) }
        let stuck = entry(99, age: 10 * 86_400, state: "verification_required")
        let result = RelayAgentMaintenance.recentActions(morning + old + [stuck], now: now)
        #expect(result.entries.count == 18)
        #expect(Set(result.entries.map(\.id)).isSuperset(of: morning.map(\.id)))
        #expect(result.entries.contains { $0.id == stuck.id })
        #expect(result.omitted == old.count)
        let capped = RelayAgentMaintenance.recentActions(morning, now: now, limit: 10)
        #expect(capped.entries.count == 10 && capped.omitted == 7)
    }
}

/// Case 5: an update result reports old → new from the native probes.
@Test func anUpdateResultReportsTheObservedVersionTransition() {
    var before = RelayAgentMaintenanceProbe(version: 1); before.runningVersion = "0.169.0"; before.installedVersion = "0.170.0"
    var after = RelayAgentMaintenanceProbe(version: 1); after.runningVersion = "0.170.0"
    #expect(RelayAgentMaintenancePolicy.updateVersionFields(before: before, after: after) ==
        ["from_version": .string("0.169.0"), "to_version": .string("0.170.0"), "version_transition": .string("0.169.0 → 0.170.0")])
    // A probe without a running version says unknown, not the installed one.
    after.runningVersion = nil
    #expect(RelayAgentMaintenancePolicy.updateVersionFields(before: before, after: after)["to_version"] == .string("unknown"))
}
