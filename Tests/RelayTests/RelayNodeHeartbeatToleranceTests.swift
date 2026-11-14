import Darwin
import Foundation
import Testing
@testable import Relay

/// 2026-10-22: dandy-07 under NFS pressure answered one heartbeat late and the
/// watchdog restarted the shared SSH, reattaching ~35 panes at once. A single
/// slow reply, or a probe followed by pane output, must not restart the node;
/// several consecutive probes with no inbound data at all still must.
private final class HeartbeatFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RelayWireFrame] = []
    func write(type: RelayWireType, payload: Data) throws { append(type, payload) }
    func writeAsync(type: RelayWireType, payload: Data) { append(type, payload) }
    private func append(_ type: RelayWireType, _ payload: Data) {
        lock.lock(); recorded.append(.init(type: type, payload: payload)); lock.unlock()
    }
    var pings: [RelayWireFrame] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.type == .ping }
    }
}

private final class HeartbeatClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000_000
    var now: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ uptime: UInt64) { lock.lock(); value = uptime; lock.unlock() }
}

private let second: UInt64 = 1_000_000_000

@Suite(.serialized)
struct RelayNodeHeartbeatToleranceTests {
    private struct Fixture {
        let node: RelayNodeConnection
        let writer: HeartbeatFrameWriter
        let clock: HeartbeatClock
        let start: UInt64

        /// One timer tick at `start + seconds`; true when it sent a probe
        /// (false: the watchdog restarted the transport instead).
        @discardableResult
        func tick(at seconds: Double) -> Bool {
            clock.set(start + UInt64(seconds * Double(second)))
            let before = writer.pings.count
            node.sendHeartbeat()
            return writer.pings.count == before + 1
        }

        func paneOutput(at seconds: Double) {
            clock.set(start + UInt64(seconds * Double(second)))
            let frame = RelayWireFrame.hostEvent(sessionID: "heartbeat-pane",
                inner: .init(type: .output, payload: Data("still working".utf8)))!
            node.receiveAttachedFrame(frame, generation: 0)
        }

        /// Answers the most recent probe.
        func reply(at seconds: Double) {
            clock.set(start + UInt64(seconds * Double(second)))
            let ping = writer.pings.last!
            node.receiveAttachedFrame(.init(type: .pong, payload: ping.payload), generation: 0)
        }

        func watchdogRecords() -> [RelayDiagnosticEvent] {
            RelayDiagnostics.shared.snapshot().events.filter {
                $0.name == "heartbeat-watchdog" && $0.details["connection_id"] == node.diagnosticID
            }
        }
    }

    private func fixture(_ name: String) -> Fixture {
        let clock = HeartbeatClock()
        let writer = HeartbeatFrameWriter()
        let node = RelayNodeConnection(profile: .init(name: name, host: "\(name).heartbeat.invalid"),
            attachedFrameWriter: writer, uptime: { clock.now })
        return Fixture(node: node, writer: writer, clock: clock, start: clock.now)
    }

    @Test func threshold() {
        #expect(RelayHeartbeatPolicy.restartMisses == 3)
    }

    @Test func expiredProbeFollowedByInboundIsDroppedUncounted() {
        let timeout = RelayHeartbeatPolicy.timeoutNanoseconds
        let verdict = RelayHeartbeatPolicy.shouldRestart(
            pending: [1: 100, 2: 100 + timeout], lastInbound: 101, now: 100 + timeout, consecutiveMisses: 2
        )
        #expect(verdict.restart == false)
        #expect(verdict.misses == 2)
        #expect(verdict.expired == [1])
    }

    @Test func inboundAtTheSendInstantDoesNotCoverTheProbe() {
        let timeout = RelayHeartbeatPolicy.timeoutNanoseconds
        let verdict = RelayHeartbeatPolicy.shouldRestart(
            pending: [1: 100], lastInbound: 100, now: 100 + timeout, consecutiveMisses: 0
        )
        #expect(verdict.misses == 1)
        #expect(verdict.expired == [1])
    }

    @Test func silentProbesRestartAtTheThresholdNotBefore() {
        let timeout = RelayHeartbeatPolicy.timeoutNanoseconds
        let pending: [UInt64: UInt64] = [7: 100, 8: 100 + timeout]
        let below = RelayHeartbeatPolicy.shouldRestart(
            pending: pending, lastInbound: nil, now: 100 + timeout, consecutiveMisses: 1
        )
        #expect(below.restart == false)
        #expect(below.misses == 2)
        let at = RelayHeartbeatPolicy.shouldRestart(
            pending: pending, lastInbound: 50, now: 100 + timeout, consecutiveMisses: 2
        )
        #expect(at.restart == true)
        #expect(at.misses == 3)
        let fresh = RelayHeartbeatPolicy.shouldRestart(
            pending: pending, lastInbound: nil, now: 99 + timeout, consecutiveMisses: 2
        )
        #expect(fresh.restart == false)
        #expect(fresh.expired.isEmpty)
    }

    @Test func singleSlowReplyKeepsTheTransport() {
        let f = fixture("heartbeat-slow-reply")
        #expect(f.tick(at: 0))
        #expect(f.tick(at: 2))
        #expect(f.tick(at: 4))
        #expect(f.tick(at: 6)) // probe 1 missed once: keep probing
        f.reply(at: 6.5)        // the next probe is answered
        for step in 4..<20 {
            #expect(f.tick(at: Double(step * 2)))
            f.reply(at: Double(step * 2) + 0.1)
        }
        #expect(f.watchdogRecords().isEmpty)
    }

    @Test func paneOutputDuringAnExpiredProbeResetsTheMisses() {
        let f = fixture("heartbeat-pane-output")
        for seconds in [0.0, 2, 4, 6, 8] { #expect(f.tick(at: seconds)) } // two misses
        f.paneOutput(at: 8.5)
        // Probes sent before the output are covered; three fresh misses are needed.
        for seconds in [10.0, 12, 14, 16, 18] { #expect(f.tick(at: seconds)) }
        #expect(f.tick(at: 20) == false)
        #expect(f.watchdogRecords().count == 1)
    }

    /// relayd node pings the app every 5 s (node_ping_echo). Those pings come
    /// from the node process, not the supervisor, so a supervisor that stopped
    /// answering must still be restarted after exactly the threshold.
    @Test func nodePingsDoNotHideASilentSupervisor() throws {
        let f = fixture("heartbeat-node-pings")
        let nodePing = { (seconds: Double) in
            f.clock.set(f.start + UInt64(seconds * Double(second)))
            f.node.receiveAttachedFrame(.init(type: .ping, payload: Data([0, 0, 0, 0, 0, 0, 0, 9])), generation: 0)
        }
        for seconds in [0.0, 2, 4, 6, 8] {
            #expect(f.tick(at: seconds))
            nodePing(seconds + 1)
        }
        #expect(f.tick(at: 10) == false)
        let record = try #require(f.watchdogRecords().first)
        #expect(record.details["consecutive_misses"] == "3")
    }

    @Test func totalSilenceRestartsAfterExactlyTheThreshold() throws {
        let f = fixture("heartbeat-silence")
        for seconds in [0.0, 2, 4, 6, 8] { #expect(f.tick(at: seconds)) }
        #expect(f.watchdogRecords().isEmpty)
        #expect(f.tick(at: 10) == false)
        #expect(f.tick(at: 12) == false)
        let record = try #require(f.watchdogRecords().first)
        #expect(f.watchdogRecords().count == 2)
        #expect(record.details["action"] == "restart-ssh")
        #expect(record.details["missed"] == "1")
        #expect(record.details["consecutive_misses"] == "3")
        #expect(record.details["last_inbound_age_ms"] == "none")
    }

    @Test func replyAfterTwoMissesResetsTheCount() {
        let f = fixture("heartbeat-late-reply")
        for seconds in [0.0, 2, 4, 6, 8] { #expect(f.tick(at: seconds)) }
        f.reply(at: 8.5)
        for seconds in [10.0, 12, 14, 16, 18] { #expect(f.tick(at: seconds)) }
        #expect(f.tick(at: 20) == false)
        let record = f.watchdogRecords().first
        #expect(record?.details["last_inbound_age_ms"] == "11500")
    }

    @Test func sleepStillClearsProbesAndSendsOneOnWake() {
        let f = fixture("heartbeat-sleep")
        for seconds in [0.0, 2, 4, 6, 8] { #expect(f.tick(at: seconds)) }
        f.node.setSystemSleeping(true)
        #expect(f.tick(at: 10) == false)
        #expect(f.watchdogRecords().isEmpty)
        f.clock.set(f.start + 60 * second)
        let before = f.writer.pings.count
        f.node.setSystemSleeping(false)
        #expect(f.writer.pings.count == before + 1)
        // Wake starts a fresh count: probes from before sleep are gone.
        for seconds in [62.0, 64, 66, 68] { #expect(f.tick(at: seconds)) }
        #expect(f.tick(at: 70) == false)
    }

    /// Root's review schedule (INBOUND_BYTE_PROGRESS_RESTART) on the node's own
    /// reader, readNodeFrame, with the real parser and a pipe: one byte is read
    /// at t=1,3,5,7,9 s before the ticks at 2,4,6,8,10 s. A frame still
    /// incomplete at the end must keep the transport like five whole frames do.
    @Test(arguments: [false, true])
    func bytesInsideAnIncompleteFrameKeepTheTransport(partial: Bool) throws {
        let f = fixture("heartbeat-byte-progress-\(partial)")
        let pipe = Pipe(), source = pipe.fileHandleForReading
        let done = DispatchSemaphore(value: 0), completed = HeartbeatFrameWriter()
        let reader = Thread {
            defer { done.signal() }
            var fragments = RelayWireFragmentAssembler()
            while (try? f.node.readNodeFrame(from: source, fragments: &fragments, generation: 0)) != nil {
                completed.writeAsync(type: .ping, payload: Data())
            }
        }
        reader.start()
        defer {
            try? pipe.fileHandleForWriting.close()
            _ = done.wait(timeout: .now() + 5)
            try? source.close()
        }
        func drained(frames: Int) -> Bool {
            let limit = Date().addingTimeInterval(5)
            repeat {
                var descriptor = pollfd(fd: source.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&descriptor, 1, 0) == 0 && completed.pings.count == frames { return true }
                Thread.sleep(forTimeInterval: 0.001)
            } while Date() < limit
            return false
        }
        #expect(f.tick(at: 0))
        for step in 0..<5 {
            f.clock.set(f.start + UInt64(step * 2 + 1) * second)
            if !partial || step == 0 {
                var length = (partial ? UInt32(64) : 1).bigEndian
                var header = Data([RelayWireType.output.rawValue])
                withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
                try pipe.fileHandleForWriting.write(contentsOf: header)
            }
            try pipe.fileHandleForWriting.write(contentsOf: Data([0x78]))
            try #require(drained(frames: partial ? 0 : step + 1))
            #expect(f.tick(at: Double(step * 2 + 2)), "restarted at \(step * 2 + 2) s")
        }
        #expect(f.watchdogRecords().isEmpty)
    }

    /// Only payload bytes arrive across the timeout window: the 5-byte header
    /// at t=1 s, then one payload byte at t=3,5,...,17 s with a tick after each
    /// and no pong. Progress inside the payload, not just the header, must
    /// keep the transport (header-only progress restarts at 12 s).
    @Test func payloadBytesAloneKeepTheTransport() throws {
        let f = fixture("heartbeat-payload-progress")
        let pipe = Pipe(), source = pipe.fileHandleForReading
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            defer { done.signal() }
            var fragments = RelayWireFragmentAssembler()
            _ = try? f.node.readNodeFrame(from: source, fragments: &fragments, generation: 0)
        }
        reader.start()
        defer {
            try? pipe.fileHandleForWriting.close()
            _ = done.wait(timeout: .now() + 5)
            try? source.close()
        }
        func drained() -> Bool {
            let limit = Date().addingTimeInterval(5)
            repeat {
                var descriptor = pollfd(fd: source.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if Darwin.poll(&descriptor, 1, 0) == 0 { return true }
                Thread.sleep(forTimeInterval: 0.001)
            } while Date() < limit
            return false
        }
        var length = UInt32(64).bigEndian
        var header = Data([RelayWireType.output.rawValue])
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        #expect(f.tick(at: 0))
        for step in 0..<9 {
            f.clock.set(f.start + UInt64(step * 2 + 1) * second)
            try pipe.fileHandleForWriting.write(contentsOf: step == 0 ? header : Data([0x78]))
            try #require(drained())
            #expect(f.tick(at: Double(step * 2 + 2)), "restarted at \(step * 2 + 2) s")
        }
        #expect(f.watchdogRecords().isEmpty)
    }
}
