import Foundation
import Testing
@testable import Relay

@Suite("Account move receipts")
struct RelayAccountMoveReceiptsTests {
    private let instance = UUID()

    private func request(_ id: UUID = UUID(), pane: UUID = UUID(), account: String = "personal") -> MCPMovePaneAccountRequest {
        MCPMovePaneAccountRequest(instance: instance, requestID: id, paneID: pane, account: account)
    }

    private let moving = ["status": "moving"]
    private let refused = ["status": "refused", "message": "The agent is busy."]

    @Test("300 refused moves in a row are all answered; the store stays at its cap")
    func refusedMovesNeverFillTheStore() {
        var receipts = RelayAccountMoveReceipts()
        let start = Date()
        for index in 0..<300 {
            let input = request()
            let now = start.addingTimeInterval(Double(index))
            #expect(receipts.lookup(input) == .new)
            #expect(receipts.begin(input, result: moving, now: now) == true, "request \(index) was refused a slot")
            receipts.finish(input.requestID, result: refused, now: now)
            #expect(receipts.lookup(input) == .replay(refused))
        }
        #expect(receipts.count <= receipts.cap)
    }

    @Test("A move in progress survives cap pressure; only finished receipts are evicted")
    func inProgressReceiptsAreNeverEvicted() {
        var receipts = RelayAccountMoveReceipts(cap: 8)
        let start = Date()
        let running = (0..<7).map { _ in request() }
        for input in running { #expect(receipts.begin(input, result: moving, now: start) == true) }
        for index in 0..<50 {
            let input = request()
            let now = start.addingTimeInterval(Double(index + 1))
            #expect(receipts.begin(input, result: moving, now: now) == true)
            receipts.finish(input.requestID, result: refused, now: now)
        }
        for input in running { #expect(receipts.lookup(input) == .replay(moving)) }
        #expect(receipts.inProgress == 7)

        // With every slot in progress, a new move is refused instead of evicting one.
        let last = request()
        #expect(receipts.begin(last, result: moving, now: start.addingTimeInterval(100)) == true)
        #expect(receipts.begin(request(), result: moving, now: start.addingTimeInterval(101)) == false)
        for input in running { #expect(receipts.lookup(input) == .replay(moving)) }
        #expect(receipts.lookup(last) == .replay(moving))

        // A finished move frees its slot for the next one.
        receipts.finish(last.requestID, result: refused, now: start.addingTimeInterval(102))
        #expect(receipts.begin(request(), result: moving, now: start.addingTimeInterval(103)) == true)
        for input in running { #expect(receipts.lookup(input) == .replay(moving)) }
    }

    @Test("Within the retention window the same request_id replays its receipt; a changed request conflicts")
    func replayWithinRetention() {
        var receipts = RelayAccountMoveReceipts(cap: 16, retention: 600)
        let start = Date()
        let input = request()
        let verified = ["status": "verified", "message": "Moved."]
        #expect(receipts.begin(input, result: moving, now: start) == true)
        #expect(receipts.lookup(input) == .replay(moving))
        receipts.finish(input.requestID, result: verified, now: start.addingTimeInterval(5))
        // Other traffic inside the window, below the cap, keeps it.
        for index in 0..<10 {
            let other = request()
            #expect(receipts.begin(other, result: moving, now: start.addingTimeInterval(Double(10 + index))) == true)
            receipts.finish(other.requestID, result: refused, now: start.addingTimeInterval(Double(10 + index)))
        }
        #expect(receipts.lookup(input) == .replay(verified))
        let changed = MCPMovePaneAccountRequest(instance: instance, requestID: input.requestID, paneID: input.paneID, account: "work")
        #expect(receipts.lookup(changed) == .conflict)
        #expect(receipts.begin(input, result: moving, now: start.addingTimeInterval(30)) == false)
        #expect(receipts.lookup(input) == .replay(verified))
    }

    @Test("An evicted request_id is answered as expired and never runs again")
    func expiredRequestIDsAreNotRerun() {
        var receipts = RelayAccountMoveReceipts(cap: 4, retention: 600)
        let start = Date()
        let old = request()
        #expect(receipts.begin(old, result: moving, now: start) == true)
        receipts.finish(old.requestID, result: refused, now: start)

        // Past retention, the next begin prunes it.
        let next = request()
        #expect(receipts.begin(next, result: moving, now: start.addingTimeInterval(601)) == true)
        #expect(receipts.lookup(old) == .expired)
        #expect(receipts.begin(old, result: moving, now: start.addingTimeInterval(602)) == false)
        #expect(receipts.lookup(old) == .expired)

        // Under cap pressure, the oldest finished receipt goes first.
        var pressed = RelayAccountMoveReceipts(cap: 3, retention: 600)
        let ids = (0..<4).map { _ in request() }
        for (index, input) in ids.enumerated() {
            #expect(pressed.begin(input, result: moving, now: start.addingTimeInterval(Double(index))) == true)
            pressed.finish(input.requestID, result: refused, now: start.addingTimeInterval(Double(index)))
        }
        #expect(pressed.lookup(ids[0]) == .expired)
        #expect(pressed.lookup(ids[1]) == .replay(refused))
        #expect(pressed.lookup(ids[3]) == .replay(refused))
        #expect(RelayAccountMoveReceipts.expiredMessage.contains("nothing was run"))
    }

    @Test("Used request_ids are never forgotten, whatever the receipt churn")
    func usedRequestIDsAreNeverForgotten() {
        var receipts = RelayAccountMoveReceipts(cap: 1, retention: 600)
        let start = Date()
        let ids = (0..<5000).map { _ in request() }
        for (index, input) in ids.enumerated() {
            #expect(receipts.begin(input, result: moving, now: start.addingTimeInterval(Double(index))) == true)
            receipts.finish(input.requestID, result: refused, now: start.addingTimeInterval(Double(index)))
        }
        #expect(receipts.count == 1)
        #expect(receipts.usedCount == 5000)
        #expect(receipts.lookup(ids[4999]) == .replay(refused))
        let earlier = ids[0..<4999].map { receipts.lookup($0) }
        #expect(earlier.allSatisfy { $0 == .expired })
        #expect(receipts.begin(ids[0], result: moving, now: start.addingTimeInterval(6000)) == false)
    }

    @Test("At the used-id ceiling new moves are refused and nothing is forgotten")
    func usedCeilingRefusesWithoutEvicting() {
        var receipts = RelayAccountMoveReceipts(cap: 2, retention: 600, expiredCap: 3)
        let start = Date()
        let ids = (0..<3).map { _ in request() }
        for (index, input) in ids.enumerated() {
            #expect(receipts.begin(input, result: moving, now: start.addingTimeInterval(Double(index))) == true)
            receipts.finish(input.requestID, result: refused, now: start.addingTimeInterval(Double(index)))
        }
        #expect(receipts.usedCeilingReached)
        let next = request()
        #expect(receipts.begin(next, result: moving, now: start.addingTimeInterval(10)) == false)
        #expect(receipts.lookup(next) == .new)
        #expect(receipts.usedCount == 3)
        #expect(receipts.lookup(ids[0]) == .expired)
        #expect(receipts.lookup(ids[2]) == .replay(refused))
        #expect(RelayAccountMoveReceipts.usedCeilingMessage.contains("restart Relay"))
        #expect(RelayAccountMoveReceipts().expiredCap == 1_000_000)
    }
}
