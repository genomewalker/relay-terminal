import Foundation

/// Where one pane's delay comes from, measured inside the app (no protocol
/// change): the shared link's heartbeat round trip, the host's time to accept
/// input (input acknowledgement minus the link), the program's time to answer
/// (first output after the acknowledgement) and the Mac's time from output
/// arrival until the batch is handed to the terminal parser (display batching
/// and queueing; parsing and the GPU frame are not included).
struct RelayPaneDelayMeter {
    struct Stat: Codable, Equatable { let samples: Int; let medianMs: Double; let p95Ms: Double }
    struct Summary: Codable, Equatable { let link: Stat?; let host: Stat?; let program: Stat?; let draw: Stat? }

    static let capacity = 64
    static let pendingInputLimit = 256
    /// Output later than this after an acknowledgement is not an answer to it.
    static let programWindowNanoseconds: UInt64 = 5_000_000_000

    private var link: [Double] = []
    private var host: [Double] = []
    private var program: [Double] = []
    private var draw: [Double] = []
    private var pending: [UInt64: UInt64] = [:]
    private var pendingOrder: [UInt64] = []
    private var lastAcknowledgement: UInt64?

    mutating func linkSample(milliseconds: Double) { Self.push(&link, milliseconds) }

    mutating func inputSent(sequence: UInt64, at: UInt64) {
        if pending.updateValue(at, forKey: sequence) == nil { pendingOrder.append(sequence) }
        while pendingOrder.count > Self.pendingInputLimit { pending.removeValue(forKey: pendingOrder.removeFirst()) }
    }

    mutating func inputAcknowledged(sequence: UInt64, at: UInt64, linkMilliseconds: Double?) {
        guard let sent = pending.removeValue(forKey: sequence) else { return }
        pendingOrder.removeAll { $0 == sequence }
        Self.push(&host, max(0, Self.milliseconds(at &- sent) - (linkMilliseconds ?? 0)))
        lastAcknowledgement = at
    }

    mutating func outputArrived(at: UInt64) {
        guard let acknowledged = lastAcknowledgement else { return }
        lastAcknowledgement = nil
        let elapsed = at &- acknowledged
        if at >= acknowledged, elapsed <= Self.programWindowNanoseconds { Self.push(&program, Self.milliseconds(elapsed)) }
    }

    mutating func drawn(arrivedAt: UInt64, at: UInt64) {
        guard at >= arrivedAt else { return }
        Self.push(&draw, Self.milliseconds(at - arrivedAt))
    }

    func summary(link: Stat? = nil) -> Summary {
        Summary(link: link ?? linkStat(), host: Self.stat(host), program: Self.stat(program), draw: Self.stat(draw))
    }

    func linkStat() -> Stat? { Self.stat(link) }

    private static func push(_ values: inout [Double], _ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

    static func stat(_ values: [Double]) -> Stat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return Stat(samples: sorted.count, medianMs: (at(0.5) * 10).rounded() / 10, p95Ms: (at(0.95) * 10).rounded() / 10)
    }
}

/// Every pane's delay split, written to `pane-delays.json` in Relay's
/// Application Support folder every 10 s while there is something new.
final class RelayPaneDelayStore: @unchecked Sendable {
    static let shared = RelayPaneDelayStore()
    static let writeIntervalSeconds = 10

    private let lock = NSLock()
    private var links: [String: RelayPaneDelayMeter] = [:]
    private var panes: [String: (host: String, meter: RelayPaneDelayMeter)] = [:]
    private var dirty = false
    private var writerStarted = false
    var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    func link(host: String, milliseconds: Double) {
        update { $0.links[host, default: RelayPaneDelayMeter()].linkSample(milliseconds: milliseconds) }
    }

    func inputSent(pane: String, host: String, sequence: UInt64) {
        let at = now()
        update { store in
            var entry = store.panes[pane] ?? (host, RelayPaneDelayMeter())
            entry.host = host
            entry.meter.inputSent(sequence: sequence, at: at)
            store.panes[pane] = entry
        }
    }

    func inputAcknowledged(pane: String, sequence: UInt64) {
        let at = now()
        update { store in
            guard var entry = store.panes[pane] else { return }
            let link = store.links[entry.host]?.linkStat()?.medianMs
            entry.meter.inputAcknowledged(sequence: sequence, at: at, linkMilliseconds: link)
            store.panes[pane] = entry
        }
    }

    func outputArrived(pane: String) {
        let at = now()
        update { store in store.panes[pane]?.meter.outputArrived(at: at) }
    }

    func drawn(pane: String, arrivedAt: UInt64) {
        let at = now()
        update { store in
            var entry = store.panes[pane] ?? ("", RelayPaneDelayMeter())
            entry.meter.drawn(arrivedAt: arrivedAt, at: at)
            store.panes[pane] = entry
        }
    }

    private var replays: [String: RelayReplayMeter] = [:]

    func replayBegan(pane: String) {
        let at = now()
        update { $0.replays[pane, default: RelayReplayMeter()].began(at: at) }
    }

    func replayCaughtUp(pane: String, bytes: Int) {
        let at = now()
        update { $0.replays[pane]?.caughtUp(bytes: bytes, at: at) }
    }

    /// Records the reconnect and logs one line per reconnect.
    func replayDrawn(pane: String, committedBytes: Int) {
        let at = now()
        lock.lock()
        let sample = replays[pane]?.drawn(at: at)
        if sample != nil { dirty = true }
        lock.unlock()
        guard let sample else { return }
        RelayDiagnostics.shared.record(category: "pane-delay", name: "reconnect-replay", details: [
            "pane_id": pane, "replayed_bytes": String(sample.bytes), "committed_bytes": String(committedBytes),
            "caught_up_ms": String(format: "%.1f", sample.waitMs), "drawn_ms": String(format: "%.1f", sample.drawMs),
        ])
    }

    struct Report: Codable, Equatable {
        struct Pane: Codable, Equatable {
            let host: String
            let delay: RelayPaneDelayMeter.Summary
            var reconnects: RelayReplayMeter.Summary? = nil
        }
        let hosts: [String: RelayPaneDelayMeter.Stat]
        let panes: [String: Pane]
    }

    func report() -> Report {
        lock.lock(); defer { lock.unlock() }
        var hosts: [String: RelayPaneDelayMeter.Stat] = [:]
        for (key, meter) in links { if let stat = meter.linkStat() { hosts[key] = stat } }
        var result: [String: Report.Pane] = [:]
        for (id, entry) in panes {
            result[id] = .init(host: entry.host, delay: entry.meter.summary(link: hosts[entry.host]),
                               reconnects: replays[id]?.summary())
        }
        for (id, meter) in replays where result[id] == nil {
            guard let summary = meter.summary() else { continue }
            result[id] = .init(host: "", delay: RelayPaneDelayMeter().summary(), reconnects: summary)
        }
        return Report(hosts: hosts, panes: result)
    }

    private func update(_ body: (RelayPaneDelayStore) -> Void) {
        lock.lock()
        body(self)
        dirty = true
        let start = !writerStarted && !RelayLaunchMode.isRunningTests
        if start { writerStarted = true }
        lock.unlock()
        if start { scheduleWrite() }
    }

    private func scheduleWrite() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(Self.writeIntervalSeconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let changed = self.dirty
            self.dirty = false
            self.lock.unlock()
            if changed { self.write() }
            self.scheduleWrite()
        }
    }

    private func write() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = base.appendingPathComponent("Relay/pane-delays.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// One pane's reconnect replays: bytes relayd replayed, the wait until it
/// said caught up, and the time until the rebuilt screen was parsed.
struct RelayReplayMeter {
    struct Sample: Codable, Equatable { let bytes: Int; let waitMs: Double; let drawMs: Double }
    struct Summary: Codable, Equatable {
        let count: Int
        let bytesMedian: Int; let bytesMax: Int
        let drawMsMedian: Double; let drawMsP95: Double; let drawMsMax: Double
        let last: Sample
    }
    private var started: UInt64?
    private var caught: (bytes: Int, at: UInt64)?
    private var samples: [Sample] = []

    /// A reconnect that begins again before it finished keeps its first start.
    mutating func began(at: UInt64) {
        if started == nil { started = at }
        caught = nil
    }

    mutating func caughtUp(bytes: Int, at: UInt64) {
        guard started != nil else { return }
        caught = (bytes, at)
    }

    /// The rebuilt screen has been parsed; one sample per reconnect.
    mutating func drawn(at: UInt64) -> Sample? {
        guard let start = started, let caught, at >= start, caught.at >= start else { return nil }
        started = nil
        self.caught = nil
        let sample = Sample(bytes: caught.bytes, waitMs: Double(caught.at - start) / 1_000_000,
                            drawMs: Double(at - start) / 1_000_000)
        samples.append(sample)
        if samples.count > RelayPaneDelayMeter.capacity { samples.removeFirst(samples.count - RelayPaneDelayMeter.capacity) }
        return sample
    }

    func summary() -> Summary? {
        guard let last = samples.last else { return nil }
        let bytes = samples.map(\.bytes).sorted()
        let draw = RelayPaneDelayMeter.stat(samples.map(\.drawMs))
        return Summary(count: samples.count, bytesMedian: bytes[bytes.count / 2], bytesMax: bytes.last ?? 0,
                       drawMsMedian: draw?.medianMs ?? 0, drawMsP95: draw?.p95Ms ?? 0,
                       drawMsMax: samples.map(\.drawMs).max() ?? 0, last: last)
    }
}
