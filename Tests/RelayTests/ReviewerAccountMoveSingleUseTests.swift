import Foundation
import Testing
@testable import Relay

@Suite("Reviewer account move single use")
struct ReviewerAccountMoveSingleUseTests {
    @Test func aCompletedRequestMustNotBecomeNewAfterTombstonePressure() {
        var receipts = RelayAccountMoveReceipts()
        let instance = UUID(), pane = UUID(), start = Date()
        let old = MCPMovePaneAccountRequest(instance: instance, requestID: UUID(), paneID: pane, account: "personal")
        let firstAdmitted = receipts.begin(old, result: ["status": "moving"], now: start)
        #expect(firstAdmitted)
        receipts.finish(old.requestID, result: ["status": "verified"], now: start)
        for index in 1...4353 {
            let input = MCPMovePaneAccountRequest(instance: instance, requestID: UUID(), paneID: pane, account: "work")
            let now = start.addingTimeInterval(Double(index))
            let admitted = receipts.begin(input, result: ["status": "moving"], now: now)
            #expect(admitted)
            receipts.finish(input.requestID, result: ["status": "refused"], now: now)
        }
        let lookup = receipts.lookup(old)
        let readmitted = receipts.begin(old, result: ["status": "moving"], now: start.addingTimeInterval(4354))
        print("REVIEWER defaults cap=\(receipts.cap) expiredCap=\(receipts.expiredCap) oldLookup=\(lookup) readmitted=\(readmitted)")
        #expect(lookup == .expired)
        #expect(!readmitted)
    }
}
