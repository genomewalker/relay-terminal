import Foundation
import os

/// Low-overhead counters for the hot terminal path. Signposts remain available
/// in Instruments, while diagnostics receive one aggregate record per window
/// instead of one event per network packet.
final class RelayPerformance: @unchecked Sendable {
    static let shared = RelayPerformance()

    private let lock = NSLock()
    private let signposter = OSSignposter(subsystem: "com.relay.terminal", category: "performance")
    private var windowStarted = DispatchTime.now().uptimeNanoseconds
    private var batchCount = 0
    private var byteCount = 0
    private var maximumBatchBytes = 0
    private var maximumPendingBytes = 0
    private var overloadedSamples = 0
    private let reportingIntervalNanoseconds: UInt64 = 10_000_000_000

    private init() {}

    func recordTerminalBatch(bytes: Int, pendingBytes: Int) {
        if signposter.isEnabled {
            signposter.emitEvent(
                "TerminalBatch",
                "bytes=\(bytes) pending=\(pendingBytes)"
            )
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        batchCount += 1
        byteCount += bytes
        maximumBatchBytes = max(maximumBatchBytes, bytes)
        maximumPendingBytes = max(maximumPendingBytes, pendingBytes)
        if pendingBytes >= 2 << 20 { overloadedSamples += 1 }
        guard now &- windowStarted >= reportingIntervalNanoseconds else {
            lock.unlock()
            return
        }
        let report = (
            batches: batchCount,
            bytes: byteCount,
            maxBatch: maximumBatchBytes,
            maxPending: maximumPendingBytes,
            overloads: overloadedSamples
        )
        windowStarted = now
        batchCount = 0
        byteCount = 0
        maximumBatchBytes = 0
        maximumPendingBytes = 0
        overloadedSamples = 0
        lock.unlock()

        RelayDiagnostics.shared.record(category: "performance", name: "terminal-window", details: [
            "batches": String(report.batches),
            "bytes": String(report.bytes),
            "maximum_batch_bytes": String(report.maxBatch),
            "maximum_pending_bytes": String(report.maxPending),
            "overloaded_samples": String(report.overloads),
        ])
    }
}
