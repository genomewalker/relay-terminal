import Testing
@testable import Relay

@Test("Reconnect output rejects duplicate and stale records without dropping mode restoration")
func relayOutputSequenceReconnect() {
    var cursor: UInt64 = 100
    var accepted: [UInt64] = []
    for sequence: UInt64 in [100, 99, 101, 101, 0, 102, 0] {
        if RelayOutputSequencePolicy.accepts(sequence, after: cursor) {
            accepted.append(sequence)
            cursor = max(cursor, sequence)
        }
    }
    #expect(accepted == [101, 0, 102, 0])
    #expect(cursor == 102)
    // A restarted worker may use a different sequence range. Only the explicit
    // reset makes that range acceptable; a late old record cannot do so itself.
    #expect(!RelayOutputSequencePolicy.accepts(1, after: cursor))
    cursor = 0
    #expect(RelayOutputSequencePolicy.accepts(1, after: cursor))
    #expect(RelayOutputSequencePolicy.accepts(UInt64.max, after: 0))
    #expect(!RelayOutputSequencePolicy.accepts(UInt64.max, after: UInt64.max))
}
