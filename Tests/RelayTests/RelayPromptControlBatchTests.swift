import Foundation
import Testing
@testable import Relay

@Test func promptControlBatchPreservesCompleteEditAtLimit() {
    var batch = RelayPromptControlBatch(maximumBytes: 4)
    let first = batch.append(Data([1, 2]))
    let second = batch.append(Data([3, 4]))
    let complete = batch.take()
    let empty = batch.take()
    #expect(first && second)
    #expect(complete == Data([1, 2, 3, 4]))
    #expect(empty == nil)
}

@Test func promptControlBatchDiscardsOverflowRatherThanDispatchingPrefix() {
    var batch = RelayPromptControlBatch(maximumBytes: 4)
    let prefix = batch.append(Data([1, 2, 3]))
    let overflow = batch.append(Data([4, 5]))
    #expect(prefix && !overflow && batch.overflowed)
    let suffix = batch.append(Data([6]))
    let discarded = batch.take()
    #expect(!suffix && discarded == nil && !batch.overflowed)
    let fresh = batch.append(Data([7]))
    let complete = batch.take()
    #expect(fresh && complete == Data([7]))
}

@Test func promptControlBatchRejectsSingleOversizedWriteAndSupportsReset() {
    var batch = RelayPromptControlBatch(maximumBytes: 1)
    let oversized = batch.append(Data([1, 2]))
    #expect(!oversized)
    batch.reset()
    let fresh = batch.append(Data([3]))
    let complete = batch.take()
    #expect(fresh && complete == Data([3]))
    var zero = RelayPromptControlBatch(maximumBytes: -1)
    let emptyAppend = zero.append(Data())
    let empty = zero.take()
    let rejected = zero.append(Data([1]))
    let discarded = zero.take()
    #expect(emptyAppend && empty == nil && !rejected && discarded == nil)
}
