import Foundation
import Testing
@testable import Relay

/// 0.5.113 item 2 addition (pane d415f009): relay_send_command "/goal clear"
/// returned a bare submitted_outcome_unknown next to a frame four hours old.
/// The result keeps that status and adds which part of the delivery could
/// not be confirmed, with how to clear it.
@Suite("Send-command delivery is named")
struct RelayInputDeliveryTests {
    typealias State = RelayRemoteTransport.InputDeliveryState
    let submitted = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { submitted.addingTimeInterval(3) }
    var fourHoursEarlier: Date { submitted.addingTimeInterval(-4 * 3600) }

    func fields(_ state: State?, lastOutput: Date?) -> [String: String] {
        TerminalRuntime.inputDeliveryFields(state, lastOutput: lastOutput, submittedAt: submitted, now: now)
    }

    @Test func inputHeldWhileTheTransportIsDetachedIsQueued() {
        let held = fields(.init(attached: false, acknowledgements: true, backlogBytes: 24, unacknowledgedBytes: 0), lastOutput: fourHoursEarlier)
        #expect(held["reason_code"] == "input_queued" && held["delivery"] == "queued_in_relay")
        #expect(held["how_to_clear"]?.contains("Do not resend") == true)
    }

    @Test func anUnacknowledgedInputIsUnconfirmed() {
        let pending = fields(.init(attached: true, acknowledgements: true, backlogBytes: 0, unacknowledgedBytes: 24), lastOutput: fourHoursEarlier)
        #expect(pending["reason_code"] == "input_unconfirmed" && pending["delivery"] == "sent_unacknowledged")
    }

    @Test func anAcknowledgedInputWithAnOldFrameIsRendererStale() {
        let stale = fields(.init(attached: true, acknowledgements: true, backlogBytes: 0, unacknowledgedBytes: 0), lastOutput: fourHoursEarlier)
        #expect(stale["reason_code"] == "renderer_stale" && stale["delivery"] == "written_to_terminal")
        #expect(stale["stale_seconds"] == String(4 * 3600 + 3) && stale["screen_changed"] == "false")
        #expect(stale["last_output_at"]?.isEmpty == false)
    }

    @Test func aWorkerWithoutAcknowledgementsAndNoOutputIsUnconfirmed() {
        let legacy = fields(.init(attached: true, acknowledgements: false, backlogBytes: 0, unacknowledgedBytes: 0), lastOutput: nil)
        #expect(legacy["reason_code"] == "input_unconfirmed" && legacy["delivery"] == "sent_unconfirmed")
        #expect(legacy["stale_seconds"] == nil)
    }

    @Test func anEchoedInputCarriesNoReasonCode() {
        let echoed = fields(.init(attached: true, acknowledgements: true, backlogBytes: 0, unacknowledgedBytes: 0), lastOutput: submitted.addingTimeInterval(0.2))
        #expect(echoed["reason_code"] == nil && echoed["screen_changed"] == "true" && echoed["delivery"] == "written_to_terminal")
    }
}
