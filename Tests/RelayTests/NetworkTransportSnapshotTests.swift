import Foundation
import Testing
@testable import Relay

@Test func transportReadinessRequiresRecentProtocolEvidence() {
    func snapshot(_ phase: NetworkTransportSnapshot.Phase, _ stamp: UInt64?) -> NetworkTransportSnapshot {
        .init(id: "config:host", host: "host", account: "", port: 22,
              phase: phase, generation: 1, attachedSubscriptions: 2, lastConfirmedUptime: stamp)
    }
    let now: UInt64 = 20_000_000_000
    #expect(snapshot(.ready, now).isCurrent(at: now))
    #expect(!snapshot(.ready, nil).isCurrent(at: now))
    #expect(!snapshot(.ready, now + 1).isCurrent(at: now))
    #expect(!snapshot(.ready, now - 6_000_000_001).isCurrent(at: now))
    #expect(!snapshot(.reconnecting, now).isCurrent(at: now))
    #expect(snapshot(.ready, nil).label(at: now) == "Status unconfirmed")
    #expect(snapshot(.reconnecting, now).label(at: now) == "Reconnecting")
}
