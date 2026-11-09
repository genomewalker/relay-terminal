import Foundation
import Testing
@testable import Relay

/// relay_wait_for_command: shell-reported OSC 133 command status, read-only.
@Suite struct TerminalCommandWaitTests {
    private let pane = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func osc(_ body: String) -> Data { Data("\u{001B}]133;\(body)\u{0007}".utf8) }

    private func observation(executions: UInt64, completed: UInt64, status: Int? = nil,
                             integration: Bool = true) -> TerminalSemanticPromptStateTracker.CommandObservation {
        .init(executions: executions, completedExecutions: completed, exitStatus: status, integrationSeen: integration)
    }

    @Test func trackerRecordsExitStatusAtTheCommandsGeneration() {
        let tracker = TerminalSemanticPromptStateTracker()
        #expect(!tracker.commandObservation.integrationSeen)
        _ = tracker.observe(osc("A") + osc("B"))
        #expect(tracker.commandObservation.integrationSeen)
        #expect(tracker.commandObservation.completedExecutions == 0)
        _ = tracker.observe(osc("C") + Data("output\r\n".utf8))
        var state = tracker.commandObservation
        #expect(state.executions == 1 && state.completedExecutions == 0 && state.exitStatus == nil)
        _ = tracker.observe(osc("D;42") + osc("A") + osc("B"))
        state = tracker.commandObservation
        #expect(state.executions == 1 && state.completedExecutions == 1 && state.exitStatus == 42)
        // ST terminator, a following key=value field, and a fragmented marker.
        _ = tracker.observe(osc("C"))
        _ = tracker.observe(Data("\u{001B}]133;D;0;aid=7\u{001B}".utf8))
        _ = tracker.observe(Data("\\".utf8))
        state = tracker.commandObservation
        #expect(state.completedExecutions == 2 && state.exitStatus == 0)
    }

    @Test func trackerIgnoresDuplicateOrMalformedCompletions() {
        let tracker = TerminalSemanticPromptStateTracker()
        _ = tracker.observe(osc("C") + osc("D;1"))
        // A second D for the same command does not overwrite the first.
        _ = tracker.observe(osc("D;9"))
        #expect(tracker.commandObservation.exitStatus == 1)
        _ = tracker.observe(osc("C") + osc("D;x1"))
        #expect(tracker.commandObservation.completedExecutions == 2)
        #expect(tracker.commandObservation.exitStatus == nil)
        _ = tracker.observe(osc("C") + osc("D"))
        #expect(tracker.commandObservation.completedExecutions == 3)
        #expect(tracker.commandObservation.exitStatus == nil)
    }

    @Test func replayedHistoryIsNotRecordedAsANewCompletion() {
        let tracker = TerminalSemanticPromptStateTracker()
        _ = tracker.observe(osc("C") + osc("D;0"))
        _ = tracker.observe(osc("C") + osc("D;3"), recordsCompletion: false)
        let state = tracker.commandObservation
        #expect(state.executions == 2)
        #expect(state.completedExecutions == 1 && state.exitStatus == 0)
    }

    @Test func bridgeDoesNotRecordCompletionsFromReplay() {
        let io = TerminalIOBridge()
        io.receive(osc("C") + osc("D;5"))
        #expect(io.commandContext.observation.completedExecutions == 1)
        #expect(io.commandContext.observation.exitStatus == 5)
        io.beginReplay()
        io.receive(osc("C") + osc("D;7"), remoteSequence: 0)
        #expect(io.commandContext.observation.completedExecutions == 1)
        #expect(io.commandContext.observation.exitStatus == 5)
    }

    @Test func returnedCarriesStatusAndGeneration() {
        let outcome = TerminalCommandWait.decide(observation(executions: 4, completed: 4, status: 2),
                                                 after: 3, pane: .live, producerChanged: false, deadline: false)
        #expect(outcome == .returned(exitStatus: 2, generation: 4))
        let json = TerminalCommandWait.json(outcome!, paneID: pane, after: 3)
        #expect(json["state"] as? String == "returned")
        #expect(json["exit_status"] as? Int == 2)
        #expect(json["generation"] as? UInt64 == 4)
        #expect(json["source"] as? String == "shell_reported_osc133")
        #expect((try? JSONSerialization.data(withJSONObject: json)) != nil)
        let pending = TerminalCommandWait.json(.paneExited(code: nil), paneID: pane, after: 3)
        #expect((try? JSONSerialization.data(withJSONObject: pending)) != nil)
    }

    @Test func restoredIdlePromptIsNotARunningCommand() {
        let live = TerminalSemanticPromptStateTracker()
        _ = live.observe(osc("C") + osc("D;0") + osc("C") + osc("D;0") + osc("A") + osc("B"))
        let restored = TerminalSemanticPromptStateTracker()
        #expect(restored.restore(live.persistentState))
        let idle = restored.commandObservation
        #expect(idle.executions == 2 && idle.completedExecutions == 2 && idle.exitStatus == nil)
        guard case .unknown = TerminalCommandWait.decide(idle, after: TerminalCommandWait.defaultAfter(idle),
                                                          pane: .live, producerChanged: false, deadline: true) else {
            Issue.record("a restored idle prompt must not read as running"); return
        }
        // Restored mid-command: that command's live completion is still reported.
        let busy = TerminalSemanticPromptStateTracker()
        _ = busy.observe(osc("B") + osc("C"))
        let resumed = TerminalSemanticPromptStateTracker()
        #expect(resumed.restore(busy.persistentState))
        _ = resumed.observe(osc("D;6"))
        #expect(resumed.commandObservation.completedExecutions == 1 && resumed.commandObservation.exitStatus == 6)
    }

    @Test func httpParserKeepsAGetBody() {
        let body = #"{"after":7,"timeout_ms":50000}"#
        let raw = "GET /api/panes/\(pane.uuidString.lowercased())/command-wait HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .request(let request) = RelaySidePanelHTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("GET with a body not parsed"); return
        }
        #expect(request.method == "GET")
        #expect(TerminalCommandWait.Request.decode(request.body) == .init(after: 7, timeoutMilliseconds: 50_000))
    }

    @Test func staleCompletionBeforeTheHandleIsNotReported() {
        // Generation 3 finished with 1 before the new command was submitted.
        let stale = observation(executions: 4, completed: 3, status: 1)
        #expect(TerminalCommandWait.decide(stale, after: 3, pane: .live, producerChanged: false, deadline: false) == nil)
        #expect(TerminalCommandWait.decide(stale, after: 3, pane: .live, producerChanged: false, deadline: true)
            == .running(generation: 4))
        let unstarted = observation(executions: 3, completed: 3, status: 1)
        guard case .unknown = TerminalCommandWait.decide(unstarted, after: 3, pane: .live,
                                                          producerChanged: false, deadline: true) else {
            Issue.record("an idle prompt is not a running command"); return
        }
    }

    @Test func runningOnlyAtTheDeadline() {
        let running = observation(executions: 5, completed: 4)
        #expect(TerminalCommandWait.decide(running, after: 4, pane: .live, producerChanged: false, deadline: false) == nil)
        let outcome = TerminalCommandWait.decide(running, after: 4, pane: .live, producerChanged: false, deadline: true)
        #expect(outcome == .running(generation: 5))
        #expect(TerminalCommandWait.json(outcome!, paneID: pane, after: 4)["exit_status"] == nil)
    }

    @Test func nextAfterChainsWaitsWhereRunningGenerationWouldNot() {
        // Command 5 is running at the first deadline.
        let running = TerminalCommandWait.decide(observation(executions: 5, completed: 4), after: 4,
                                                 pane: .live, producerChanged: false, deadline: true)!
        let first = TerminalCommandWait.json(running, paneID: pane, after: 4)
        #expect(first["generation"] as? UInt64 == 5)
        let next = first["next_after"] as! UInt64
        #expect(next == 4)
        // It then returns: next_after finds it, its own generation would not.
        let done = observation(executions: 5, completed: 5, status: 0)
        #expect(TerminalCommandWait.decide(done, after: next, pane: .live, producerChanged: false, deadline: false)
            == .returned(exitStatus: 0, generation: 5))
        #expect(TerminalCommandWait.decide(done, after: 5, pane: .live, producerChanged: false, deadline: false) == nil)
        let returned = TerminalCommandWait.json(.returned(exitStatus: 0, generation: 5), paneID: pane, after: next)
        #expect(returned["next_after"] as? UInt64 == 5)
        for outcome in [TerminalCommandWait.Outcome.paneExited(code: 1), .unknown(reason: "x", generation: 9)] {
            #expect(TerminalCommandWait.json(outcome, paneID: pane, after: 4)["next_after"] as? UInt64 == 4)
        }
    }

    @Test func paneExitIsDistinctFromACommandReturn() {
        let running = observation(executions: 5, completed: 4)
        let outcome = TerminalCommandWait.decide(running, after: 4, pane: .exited(code: 137),
                                                 producerChanged: false, deadline: false)
        #expect(outcome == .paneExited(code: 137))
        let json = TerminalCommandWait.json(outcome!, paneID: pane, after: 4)
        #expect(json["state"] as? String == "pane_exited" && json["exit_code"] as? Int == 137)
        // A completion the shell reported before exiting still answers the command.
        #expect(TerminalCommandWait.decide(observation(executions: 5, completed: 5, status: 0), after: 4,
                                           pane: .exited(code: 0), producerChanged: false, deadline: false)
            == .returned(exitStatus: 0, generation: 5))
    }

    @Test func unknownWithoutIntegrationOrSupport() {
        let none = observation(executions: 0, completed: 0, integration: false)
        guard case .unknown(let reason, _) = TerminalCommandWait.decide(none, after: 0, pane: .live,
                                                                        producerChanged: false, deadline: true) else {
            Issue.record("expected unknown"); return
        }
        #expect(reason.contains("no shell integration"))
        #expect(TerminalCommandWait.decide(none, after: 0, pane: .live, producerChanged: false, deadline: false) == nil)
        guard case .unknown = TerminalCommandWait.decide(none, after: 0, pane: .unsupported("not a terminal pane"),
                                                         producerChanged: false, deadline: false),
              case .unknown = TerminalCommandWait.decide(observation(executions: 2, completed: 2), after: 1,
                                                         pane: .live, producerChanged: true, deadline: false),
              case .unknown = TerminalCommandWait.decide(observation(executions: 2, completed: 1), after: 1,
                                                         pane: .disconnected, producerChanged: false, deadline: false) else {
            Issue.record("expected unknown"); return
        }
    }

    @Test func requestDecodingIsStrict() {
        #expect(TerminalCommandWait.Request.decode(Data()) == .init(after: nil, timeoutMilliseconds: 30_000))
        #expect(TerminalCommandWait.Request.decode(Data(#"{"after":7,"timeout_ms":1000}"#.utf8))
            == .init(after: 7, timeoutMilliseconds: 1000))
        for body in [#"{"after":-1}"#, #"{"after":1.5}"#, #"{"after":true}"#, #"{"timeout_ms":0}"#,
                     #"{"timeout_ms":50001}"#, #"{"text":"echo"}"#, "[]"] {
            #expect(TerminalCommandWait.Request.decode(Data(body.utf8)) == nil)
        }
    }
}
