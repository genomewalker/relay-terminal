import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Relay

/// A fake surface pointer crossing threads. It is only compared, never
/// dereferenced.
private struct SurfaceBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
    init(_ pointer: UnsafeMutableRawPointer?) { self.pointer = pointer }
}

// MARK: - Exhaustive bounded check: retiring a surface against an in-flight operation

/// Drives the real `InMemoryTerminalSurfaceAccess` with fake surface pointers
/// (never dereferenced) and a write closure that blocks at a gate until the
/// checker lets it finish, the way a Ghostty write blocks on the app mailbox.
///
/// Two actors: the main side (attach, clear, retire, enqueue, read, run the
/// deferred releases) and the output drain (its gated write finishing). A
/// sequence of steps is one interleaving of the two.
private final class RetirementHarness: @unchecked Sendable {
    let a = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    let b = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private let lock = NSLock()
    private var freed: Set<UnsafeMutableRawPointer> = []
    private var releaseCounts: [UnsafeMutableRawPointer: Int] = [:]
    private var inFlight: [UnsafeMutableRawPointer: Int] = [:]
    private var deferred: [@Sendable () -> Void] = []
    private(set) var violations: [String] = []
    private let gate = DispatchSemaphore(value: 0)
    private var writeBlocked = false
    private var writesEntered = 0
    private var payloadTarget: [UInt8: UnsafeMutableRawPointer] = [:]
    private var nextPayload: UInt8 = 1
    private(set) var access: InMemoryTerminalSurfaceAccess!
    /// Surfaces the main side has retired, and those it may retire again.
    private(set) var retired: Set<UnsafeMutableRawPointer> = []

    init() {
        access = InMemoryTerminalSurfaceAccess(
            write: { [unowned self] surface, data in self.write(surface, data) },
            processExit: { _, _, _ in },
            scheduleRelease: { [unowned self] release in
                self.lock.lock(); self.deferred.append(release); self.lock.unlock()
            }
        )
    }

    deinit {
        a.deallocate()
        b.deallocate()
    }

    func name(_ s: UnsafeMutableRawPointer?) -> String { s == a ? "A" : s == b ? "B" : "nil" }

    private func record(_ v: String) {
        lock.lock(); violations.append(v); lock.unlock()
    }

    /// The drain side. P1: never runs on a freed surface. P4: bytes enqueued
    /// for one surface never reach another.
    private func write(_ surface: UnsafeMutableRawPointer, _ data: Data) {
        lock.lock()
        if freed.contains(surface) { violations.append("P1 use-after-free: write on freed \(name(surface))") }
        for byte in data {
            if let target = payloadTarget[byte], target != surface {
                violations.append("P4 stale write: bytes for \(name(target)) reached \(name(surface))")
            }
        }
        inFlight[surface, default: 0] += 1
        writesEntered += 1
        writeBlocked = true
        lock.unlock()
        gate.wait()
        lock.lock()
        inFlight[surface, default: 1] -= 1
        writeBlocked = false
        lock.unlock()
    }

    private var enteredCount: Int { lock.lock(); defer { lock.unlock() }; return writesEntered }

    /// Waits for an exact state, not a fixed time: the drain is either idle
    /// (a `sync` on its queue returned) or blocked inside a write that started
    /// after `since`. The 2 s bound only turns a harness stall into a failure.
    private func awaitDrain(since: Int?) {
        let idle = DispatchSemaphore(value: 0)
        let access = self.access!
        Thread.detachNewThread { access.waitForPendingOutput(); idle.signal() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            lock.lock(); let blocked = writeBlocked && (since.map { writesEntered > $0 } ?? true); lock.unlock()
            if blocked || idle.wait(timeout: .now()) == .success { return }
            usleep(100)
        }
        record("harness: the drain was neither idle nor blocked after 2 s")
    }

    /// The release a retirement runs. P1: never while an operation on the
    /// surface is in flight. P2: at most once per surface.
    func release(_ retiring: UnsafeMutableRawPointer) -> @Sendable () -> Void {
        let box = SurfaceBox(retiring)
        return { [unowned self] in
            let surface = box.pointer!
            self.lock.lock()
            if (self.inFlight[surface] ?? 0) > 0 {
                self.violations.append("P1 use-after-free: \(self.name(surface)) released during its operation")
            }
            self.releaseCounts[surface, default: 0] += 1
            if self.releaseCounts[surface]! > 1 {
                self.violations.append("P2 double release of \(self.name(surface))")
            }
            self.freed.insert(surface)
            self.lock.unlock()
        }
    }

    var isWriteBlocked: Bool { lock.lock(); defer { lock.unlock() }; return writeBlocked }

    /// P3: a main-side step never blocks, even while a write is gated. Runs the
    /// step on another thread and fails if it hasn't returned within 2 s.
    func mainStep(_ label: String, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { body(); done.signal() }
        if done.wait(timeout: .now() + 2) == .timedOut {
            record("P3 main-side \(label) blocked while a write was in flight")
            return false
        }
        return true
    }

    /// Enqueues one tagged byte for the current surface and waits until the
    /// drain is inside its write (or found nothing to do).
    func enqueue() {
        let current = access.currentSurface
        lock.lock()
        let tag = nextPayload
        nextPayload &+= 1
        if let current { payloadTarget[tag] = current }
        lock.unlock()
        _ = access.enqueueWrite(Data([tag]))
    }

    /// After any main-side step: the drain is idle or blocked in a write.
    /// (Attaching a surface can flush earlier bytes and start a write.)
    func quiesce() {
        guard !isWriteBlocked else { return }
        awaitDrain(since: nil)
    }

    /// The drain's write completes; waits until it has returned.
    func finishWrite() {
        guard isWriteBlocked else { return }
        let since = enteredCount
        gate.signal()
        // The drain either goes idle or starts (and blocks in) its next batch.
        awaitDrain(since: since)
    }

    func runDeferredReleases() {
        lock.lock(); let work = deferred; deferred.removeAll(); lock.unlock()
        for release in work { release() }
    }

    func retire(_ s: UnsafeMutableRawPointer) {
        retired.insert(s)
        access.retireSurface(s, release: release(s))
    }

    /// Lets every gated write finish, then runs every deferred release.
    func settle() {
        for _ in 0..<64 {
            if !isWriteBlocked { break }
            finishWrite()
        }
        access.waitForPendingOutput()
        runDeferredReleases()
    }

    /// P2 (liveness half): once nothing is in flight, every retired surface
    /// has been released exactly once.
    func checkSettled() {
        lock.lock(); defer { lock.unlock() }
        for s in retired where releaseCounts[s] != 1 {
            violations.append("P2 retired \(name(s)) released \(releaseCounts[s] ?? 0) times after settling")
        }
        for (s, n) in inFlight where n != 0 {
            violations.append("in-flight count for \(name(s)) is \(n) after settling")
        }
    }

    var hasDeferredRelease: Bool { lock.lock(); defer { lock.unlock() }; return !deferred.isEmpty }
}

@Suite("Ghostty surface retirement bounded check", .serialized)
struct GhosttySurfaceRetirementBoundedTests {
    enum Op: CaseIterable {
        case attachA, attachB, clearCurrent, retireA, retireB, enqueue, read, finishWrite, runReleases
    }

    static let depth = 5

    @Test("Exhaustive bounded check: no use-after-free, release once, main never blocks, no stale write",
          .timeLimit(.minutes(20)))
    func boundedRetirementCheck() async throws {
        let ops = Op.allCases
        var sequences = 0, steps = 0, deferredSeen = 0, blockedRetire = 0
        for length in 1...Self.depth {
            let count = Int(pow(Double(ops.count), Double(length)))
            for index in 0..<count {
                var sequence: [Op] = [], rest = index
                for _ in 0..<length { sequence.append(ops[rest % ops.count]); rest /= ops.count }
                let h = RetirementHarness()
                var ok = true
                for op in sequence where ok {
                    let blockedBefore = h.isWriteBlocked
                    switch op {
                    case .attachA:
                        // Surfaces are never re-attached after retirement (Ghostty frees them).
                        if !h.retired.contains(h.a) { ok = h.mainStep("setSurface(A)") { h.access.setSurface(h.a) } }
                    case .attachB:
                        if !h.retired.contains(h.b) { ok = h.mainStep("setSurface(B)") { h.access.setSurface(h.b) } }
                    case .clearCurrent:
                        let current = SurfaceBox(h.access.currentSurface)
                        ok = h.mainStep("clearSurface") { _ = h.access.clearSurface(ifMatches: current.pointer) }
                    case .retireA:
                        if !h.retired.contains(h.a) {
                            if blockedBefore { blockedRetire += 1 }
                            ok = h.mainStep("retireSurface(A)") { h.retire(h.a) }
                        }
                    case .retireB:
                        if !h.retired.contains(h.b) {
                            if blockedBefore { blockedRetire += 1 }
                            ok = h.mainStep("retireSurface(B)") { h.retire(h.b) }
                        }
                    case .enqueue:
                        ok = h.mainStep("enqueueWrite") { h.enqueue() }
                    case .read:
                        ok = h.mainStep("withCurrentSurface") { _ = h.access.withCurrentSurface { _ in 0 } }
                    case .finishWrite:
                        h.finishWrite()
                    case .runReleases:
                        h.runDeferredReleases()
                    }
                    if ok, op != .finishWrite { h.quiesce() }
                    if h.hasDeferredRelease { deferredSeen += 1 }
                    steps += 1
                    if !h.violations.isEmpty { ok = false }
                }
                if ok {
                    h.settle()
                    h.checkSettled()
                }
                if let first = h.violations.first {
                    Issue.record("\(first) after \(sequence)")
                    return
                }
                h.retireRemainingForCleanup()
                sequences += 1
                if sequences % 256 == 0 { await Task.yield() }
            }
        }
        print("surface retirement bounded check: depth \(Self.depth), \(ops.count) ops, \(sequences) sequences, \(steps) steps, \(blockedRetire) retirements during a blocked write, \(deferredSeen) steps with a deferred release pending")
        #expect(sequences == (1...Self.depth).reduce(0) { $0 + Int(pow(Double(ops.count), Double($1))) })
        #expect(blockedRetire > 0, "non-vacuous: some retirements happen while a write is blocked")
        #expect(deferredSeen > 0, "non-vacuous: some releases are deferred")
    }
}

private extension RetirementHarness {
    /// Leaves no gated write behind when a sequence stops early.
    func retireRemainingForCleanup() {
        for _ in 0..<64 where isWriteBlocked { finishWrite() }
        access.setSurface(nil)
        access.waitForPendingOutput()
    }
}

// MARK: - The generation check in the gap between taking a batch and writing it

/// The bounded check gates the drain inside its write; the surface can also
/// change after the drain has taken a batch and dropped the lock but before it
/// looks the surface up. Only the generation check stops that batch reaching
/// the new surface. This pins the drain in that gap and swaps the surface.
private final class StaleBatchProbe: @unchecked Sendable {
    let a = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    let b = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private let lock = NSLock()
    private(set) var writes: [(surface: UnsafeMutableRawPointer, data: Data)] = []
    private var pinNext = false
    let inGap = DispatchSemaphore(value: 0)
    let leaveGap = DispatchSemaphore(value: 0)
    private(set) var access: InMemoryTerminalSurfaceAccess!

    init() {
        access = InMemoryTerminalSurfaceAccess(
            write: { [unowned self] surface, data in
                self.lock.lock(); self.writes.append((surface, data)); self.lock.unlock()
            },
            processExit: { _, _, _ in },
            scheduleRelease: { release in release() },
            drainWillUseSurface: { [unowned self] in
                self.lock.lock(); let pin = self.pinNext; self.pinNext = false; self.lock.unlock()
                if pin { self.inGap.signal(); self.leaveGap.wait() }
            }
        )
    }

    deinit { a.deallocate(); b.deallocate() }

    func pinNextBatch() { lock.lock(); pinNext = true; lock.unlock() }
    var recorded: [(surface: UnsafeMutableRawPointer, data: Data)] { lock.lock(); defer { lock.unlock() }; return writes }
}

@Suite("Ghostty stale batch after a surface change", .serialized)
struct GhosttyStaleBatchTests {
    @Test("A batch taken for A is dropped when the surface changes before it is written",
          arguments: ["replace", "retire-then-attach"])
    func staleBatchIsDropped(_ path: String) throws {
        let probe = StaleBatchProbe()
        let access = probe.access!
        access.setSurface(probe.a)
        probe.pinNextBatch()
        #expect(access.enqueueWrite(Data([0xA1])))
        // The drain took the A batch and is held before the surface lookup.
        try #require(probe.inGap.wait(timeout: .now() + 5) == .success, "the drain reached the gap")
        if path == "replace" {
            access.setSurface(probe.b)
        } else {
            access.retireSurface(probe.a) {}
            access.setSurface(probe.b)
        }
        probe.leaveGap.signal()
        access.waitForPendingOutput()
        #expect(probe.recorded.allSatisfy { $0.surface != probe.b || !$0.data.contains(0xA1) },
                "P4: bytes taken for A were written to B")
        #expect(probe.recorded.isEmpty, "the stale batch was dropped, not written anywhere")

        // B still works.
        #expect(access.enqueueWrite(Data([0xB1])))
        access.waitForPendingOutput()
        #expect(probe.recorded.map(\.data) == [Data([0xB1])])
        #expect(probe.recorded.allSatisfy { $0.surface == probe.b })
    }
}
