import Foundation
import Testing
@testable import Relay

/// 2026-11-19: KapK panes were "ultra slow" and nothing could say whether the
/// link, dandy-07 or the Mac was the cause. Each pane now carries its own
/// split: link, host, program and Mac draw.
@Suite("A pane's delay is split into link, host, program and Mac draw")
struct RelayPaneDelayTests {
    static func ms(_ value: Double) -> UInt64 { UInt64(value * 1_000_000) }

    @Test func oneKeystrokeIsSplitIntoItsParts() {
        var meter = RelayPaneDelayMeter()
        meter.inputSent(sequence: 7, at: Self.ms(1000))
        meter.inputAcknowledged(sequence: 7, at: Self.ms(1050), linkMilliseconds: 30)
        meter.outputArrived(at: Self.ms(1120))
        meter.drawn(arrivedAt: Self.ms(1120), at: Self.ms(1128))
        let summary = meter.summary()
        #expect(summary.host?.medianMs == 20, "acknowledgement round trip minus the link")
        #expect(summary.program?.medianMs == 70, "first output after the acknowledgement")
        #expect(summary.draw?.medianMs == 8)
    }

    @Test func onlyTheFirstOutputAfterAnAcknowledgementCountsAsTheAnswer() {
        var meter = RelayPaneDelayMeter()
        meter.outputArrived(at: Self.ms(10))
        meter.inputSent(sequence: 1, at: Self.ms(100))
        meter.inputAcknowledged(sequence: 1, at: Self.ms(140), linkMilliseconds: 40)
        meter.outputArrived(at: Self.ms(150))
        meter.outputArrived(at: Self.ms(900))
        meter.inputAcknowledged(sequence: 99, at: Self.ms(950), linkMilliseconds: 40)
        let summary = meter.summary()
        #expect(summary.program?.samples == 1 && summary.program?.medianMs == 10)
        #expect(summary.host?.samples == 1 && summary.host?.medianMs == 0, "never negative; unknown acks ignored")
    }

    @Test func percentilesUseTheMostRecentWindow() {
        var meter = RelayPaneDelayMeter()
        for i in 0..<200 { meter.linkSample(milliseconds: Double(i)) }
        let link = meter.linkStat()
        #expect(link?.samples == RelayPaneDelayMeter.capacity)
        #expect(link?.medianMs == 168 && link?.p95Ms == 196)
    }

    @Test func pendingInputsAreBounded() {
        var meter = RelayPaneDelayMeter()
        for i in 0..<1000 { meter.inputSent(sequence: UInt64(i), at: Self.ms(Double(i))) }
        meter.inputAcknowledged(sequence: 0, at: Self.ms(2000), linkMilliseconds: nil)
        meter.inputAcknowledged(sequence: 999, at: Self.ms(2000), linkMilliseconds: nil)
        #expect(meter.summary().host?.samples == 1, "the oldest pending inputs were dropped, the newest kept")
    }
}
