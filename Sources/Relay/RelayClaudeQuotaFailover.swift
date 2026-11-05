import Foundation
import Darwin

/// The wire formats are private, versioned, bounded and strict. Remote/MCP
/// settings proposals do not have a representation for these user controls.
enum RelayQuotaWire {
    enum Invalid: Error { case payload }
    static func auditAppendable(size: Int64, last: UInt8?) -> Bool {
        guard size >= 0, size <= 32 << 20 else { return false }
        return size == 0 || last == 10
    }
    static func object(_ data: Data, keys: Set<String>, limit: Int = 1 << 20) throws -> [String: Any] {
        guard data.count <= limit,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == keys else { throw Invalid.payload }
        return value
    }
}

struct RelayClaudeQuotaSettings: Codable, Equatable, Sendable {
    var enabled = true
    var source = "business"
    var target = "personal"
    var threshold = 90.0
    var weeklyThreshold = 90.0
    var targetCeiling = 95.0
    /// Missing hosts are enabled, including This Mac ("local").
    var hosts: [String: Bool] = [:]
    var valid: Bool {
        RelayAgentAccount.validLabel(source) && RelayAgentAccount.validLabel(target) && source != target &&
        threshold.isFinite && threshold > 0 && threshold <= 100 &&
        weeklyThreshold.isFinite && weeklyThreshold > 0 && weeklyThreshold <= 100 &&
        targetCeiling.isFinite && targetCeiling > 0 && targetCeiling <= 100 && hosts.count <= 256 &&
        hosts.keys.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: { $0.isNewline || $0.asciiValue == 0 }) }
    }
    static func decode(_ data: Data) throws -> Self {
        _ = try RelayQuotaWire.object(data, keys: ["enabled", "source", "target", "threshold", "weeklyThreshold", "targetCeiling", "hosts"], limit: 64 << 10)
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.valid else { throw RelayQuotaWire.Invalid.payload }
        return result
    }
    static func restored(_ data: Data?) -> Self {
        guard let data else { return .init() }
        return (try? decode(data)) ?? .init(enabled: false)
    }
}

/// Quota reads are independent of the serial move lane. A long native move
/// cannot starve observation, and one host can never have overlapping polls.
struct RelayClaudeQuotaPollSchedule {
    private var due: [String: Date] = [:]
    private var running: Set<String> = []
    mutating func begin(host: String, now: Date) -> Bool {
        guard !running.contains(host), now >= due[host, default: .distantPast] else { return false }
        running.insert(host)
        due[host] = now.addingTimeInterval(60)
        return true
    }
    mutating func finish(host: String) { running.remove(host) }
}

/// Pure decision code used by the live adapter and the exhaustive checker.
/// All effects go through a write-ahead journal. A pending intent is never
/// replayed after restart; the user gets an explicit uncertain-move notice.
struct RelayClaudeQuotaEngine {
    static let weeklyNames: Set<String> = ["seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_cowork", "seven_day_omelette"]
    struct Window: Equatable {
        var used: Double
        var reset: Date
        var observed: Date
        func current(_ now: Date) -> Bool {
            used.isFinite && (0...100).contains(used) && reset > now &&
            now >= observed && now.timeIntervalSince(observed) <= 120
        }
    }
    struct Quota: Equatable {
        var used: Double
        var reset: Date
        var observed: Date
        var weekly: [String: Window] = [:]
        /// False models a reading without a 5-hour window: `used`, `reset` and
        /// `observed` are then ignored and the weekly windows alone decide.
        /// NOT LIVE: a missing `five_hour` is not established as "no active
        /// 5-hour quota", so the scheduler's wire boundary rejects such a
        /// reading (`no_five_hour`) and never builds this state. The weekly-only
        /// semantics stay modelled and checked pending an authoritative contract.
        var fiveHourReported = true
        var windows: [String: Window] {
            guard fiveHourReported else { return weekly }
            return weekly.merging(["five_hour": .init(used: used, reset: reset, observed: observed)]) { _, five in five }
        }
        func current(_ now: Date) -> Bool {
            !weekly.isEmpty && Set(weekly.keys).isSubset(of: RelayClaudeQuotaEngine.weeklyNames) &&
                windows.values.allSatisfy { $0.current(now) }
        }
        func triggers(_ settings: RelayClaudeQuotaSettings) -> [String: Date] {
            var result: [String: Date] = [:]
            if fiveHourReported, used >= settings.threshold { result["five_hour"] = reset } // QF7
            for (name, window) in weekly where window.used >= settings.weeklyThreshold { result[name] = window.reset } // QW1 QW4
            return result
        }
        func below(_ settings: RelayClaudeQuotaSettings) -> Bool {
            (!fiveHourReported || used < settings.threshold) && weekly.values.allSatisfy { $0.used < settings.weeklyThreshold }
        }
        /// Every reported window, 5-hour included when present, below `ceiling`.
        func under(_ ceiling: Double) -> Bool {
            windows.values.allSatisfy { $0.used < ceiling }
        }
        func fenced(by previous: [String: Date], settings: RelayClaudeQuotaSettings) -> Bool {
            triggers(settings).contains { name, reset in previous[name].map { reset <= $0 } ?? false }
        }
        func canReturn(_ record: Record, now: Date) -> Bool {
            !record.triggerResets.isEmpty && record.triggerResets.allSatisfy { name, reset in
                // relayd's normalized wire rounds down to a whole second.
                guard now >= reset.addingTimeInterval(1) else { return false }
                if let window = windows[name] { return window.observed >= reset.addingTimeInterval(1) }
                // Weekly-only model (not live, see `fiveHourReported`): a 5-hour
                // trigger whose window is not reported needs every weekly window
                // observed after the reset. A missing weekly window still fences.
                return name == "five_hour" && !fiveHourReported && !weekly.isEmpty &&
                    weekly.values.allSatisfy { $0.observed >= reset.addingTimeInterval(1) }
            }
        }
    }
    struct Pane: Equatable {
        var id: UUID
        var host: String
        var label: String
        var session: String
        var process: String
        var idle: Bool
    }
    struct Record: Codable, Equatable {
        enum State: String, Codable { case moving, queued, away, returning, returned, refused, user }
        var pane: UUID
        var host: String
        var session: String
        var process: String
        var source: String
        var target: String
        var sourceDir: String
        var targetDir: String
        var reset: Date
        var state: State
        var operation: UUID
        var detail: String
        var triggerResets: [String: Date] = [:]
    }
    struct Disk: Codable, Equatable {
        var version = 2
        var records: [Record] = []
        static func decode(_ data: Data) throws -> Self {
            let top = try RelayQuotaWire.object(data, keys: ["version", "records"])
            guard let rows = top["records"] as? [[String: Any]], rows.count <= 4096 else { throw RelayQuotaWire.Invalid.payload }
            let legacyKeys: Set<String> = ["pane", "host", "session", "process", "source", "target", "sourceDir", "targetDir", "reset", "state", "operation", "detail"]
            struct Header: Decodable { var version: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 || version == 2 else { throw RelayQuotaWire.Invalid.payload }
            let legacy = version == 1
            let keys = legacy ? legacyKeys : legacyKeys.union(["triggerResets"])
            guard rows.allSatisfy({ Set($0.keys) == keys }) else { throw RelayQuotaWire.Invalid.payload }
            var normalized = top
            if legacy {
                normalized["version"] = 2
                normalized["records"] = rows.map { row in
                    var row = row
                    row["triggerResets"] = ["five_hour": row["reset"]!]
                    return row
                }
            }
            let disk = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: normalized))
            guard disk.version == 2, Set(disk.records.map(\.pane)).count == disk.records.count,
                  disk.records.allSatisfy({ r in
                      !r.host.isEmpty && r.host.utf8.count <= 256 && !r.session.isEmpty && r.session.utf8.count <= 128 &&
                      !r.process.isEmpty && r.process.utf8.count <= 256 && r.detail.utf8.count <= 1000 &&
                      RelayAgentAccount.validLabel(r.source) && RelayAgentAccount.validLabel(r.target) && r.source != r.target &&
                      RelayAgentAccount.validDirectory(r.sourceDir) && RelayAgentAccount.validDirectory(r.targetDir) &&
                      r.reset.timeIntervalSince1970 > 0 && r.reset.timeIntervalSince1970 < 253_402_300_800 &&
                      (r.state == .user || !r.triggerResets.isEmpty) && r.triggerResets.count <= 7 &&
                      Set(r.triggerResets.keys).isSubset(of: RelayClaudeQuotaEngine.weeklyNames.union(["five_hour"])) &&
                      r.triggerResets.values.allSatisfy { $0.timeIntervalSince1970 > 0 && $0.timeIntervalSince1970 < 253_402_300_800 } &&
                      (r.triggerResets.isEmpty || r.triggerResets.values.max() == r.reset)
                  }) else { throw RelayQuotaWire.Invalid.payload }
            return disk
        }
    }
    struct Move: Equatable {
        var pane: Pane
        var target: String
        var operation: UUID
        var returning: Bool
    }
    private(set) var disk: Disk
    private(set) var inFlight: Move?
    init(disk: Disk = .init()) { self.disk = disk }

    /// Audit must succeed before the intent, and the intent must be durable
    /// before terminal input. The adapter holds one async lane across awaits.
    mutating func next(settings: RelayClaudeQuotaSettings, host: String, source: Quota?, target: Quota?,
                       panes: [Pane], paused: Bool, now: Date, sourceDir: String, targetDir: String,
                       save: (Disk) throws -> Void, audit: (UUID, String) throws -> Void,
                       admit: (UUID) -> Bool = { _ in true }) throws -> Move? {
        guard inFlight == nil, settings.valid, settings.enabled, settings.hosts[host] != false,
              !paused, let source, source.current(now) else { return nil }
        for pane in panes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where pane.host == host {
            let old = disk.records.first(where: { $0.pane == pane.id })
            let returning: Bool
            if let old, old.state == .away {
                // Both native process identity and conversation must still be
                // the exact agent the scheduler resumed, not just its label.
                guard old.host == host, old.session == pane.session, old.process == pane.process,
                      old.source == settings.source, old.target == settings.target,
                      old.sourceDir == sourceDir, old.targetDir == targetDir,
                      pane.label == settings.target else { continue }
                // relayd's legacy usage wire normalizes resets to whole
                // seconds. Wait until the following whole second so a lost
                // fractional part cannot cause a premature return.
                guard source.canReturn(old, now: now), source.below(settings) else { continue } // QF2 QW2
                returning = true
            } else {
                // A manual move or an uncertain intent is a durable fence.
                if let old, old.state == .user || old.state == .moving || old.state == .returning { continue }
                if let old, old.state != .queued, source.fenced(by: old.triggerResets, settings: settings) { continue } // QF18
                guard pane.label == settings.source, !source.triggers(settings).isEmpty,
                      let target, target.current(now), target.under(settings.targetCeiling) else { continue } // QW5
                returning = false
            }
            guard pane.idle else { try audit(pane.id, "deferred_busy"); continue } // QF1
            guard admit(pane.id) else { try audit(pane.id, "deferred_budget"); continue }
            let operation = UUID()
            let move = Move(pane: pane, target: returning ? settings.source : settings.target, operation: operation, returning: returning)
            var next = disk
            next.records.removeAll { $0.pane == pane.id }
            guard next.records.count < 4096 else { throw RelayQuotaWire.Invalid.payload }
            next.records.append(Record(pane: pane.id, host: host, session: pane.session, process: pane.process,
                source: settings.source, target: settings.target, sourceDir: sourceDir, targetDir: targetDir,
                reset: returning ? old!.reset : source.triggers(settings).values.max()!, state: returning ? .returning : .moving,
                operation: operation, detail: "Move intent; interruption requires user reconciliation",
                triggerResets: returning ? old!.triggerResets : source.triggers(settings)))
            try audit(pane.id, returning ? "return_intent" : "failover_intent")
            try save(next)
            disk = next
            inFlight = move // QF3
            return move
        }
        return nil
    }

    mutating func finish(_ move: Move, success: Bool, process: String, detail: String, deferred: Bool = false,
                         save: (Disk) throws -> Void, audit: (UUID, String) throws -> Void) throws {
        guard inFlight == move else { return }
        defer { inFlight = nil }
        var next = disk
        // A user's move can revoke ownership while the native move is awaiting
        // a response. Its tombstone wins, including after a restart.
        if let i = next.records.firstIndex(where: { $0.pane == move.pane.id && $0.operation == move.operation && $0.state != .user }) {
            next.records[i].state = success ? (move.returning ? .returned : .away) :
                (deferred ? (move.returning ? .away : .queued) : .refused)
            next.records[i].process = process
            next.records[i].detail = String(detail.prefix(240))
        }
        try audit(move.pane.id, success ? "move_completed" : (deferred ? "move_deferred" : "move_refused"))
        try save(next)
        disk = next
    }

    mutating func userMoved(_ pane: Pane, source: String, target: String, save: (Disk) throws -> Void) throws {
        var next = disk
        if let i = next.records.firstIndex(where: { $0.pane == pane.id }) {
            next.records[i].state = .user
            next.records[i].operation = UUID()
            next.records[i].detail = "User claimed this pane; automatic return disabled"
        } else {
            // A pane claimed before its first scheduled move is protected too.
            guard next.records.count < 4096 else { throw RelayQuotaWire.Invalid.payload }
            next.records.append(.init(pane: pane.id, host: pane.host, session: pane.session, process: pane.process,
                source: source, target: target, sourceDir: "", targetDir: "", reset: Date(timeIntervalSince1970: 1),
                state: .user, operation: UUID(), detail: "User claimed this pane"))
        }
        try save(next)
        disk = next
    }
}

/// Atomic replacement + file and parent directory fsync. A corrupt or
/// unreadable journal disables scheduling; it never silently becomes empty.
final class RelayClaudeQuotaJournal {
    let url: URL
    private var lockFD: Int32 = -1
    init(url: URL) { self.url = url }
    deinit { if lockFD >= 0 { close(lockFD) } }
    private func lock() throws {
        guard lockFD < 0 else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw POSIXError(.EBUSY) }
        lockFD = fd
    }
    /// A bounded append-only log owned by this journal's lifetime flock.
    /// No compaction or replay; a full log stops scheduling for user review.
    func appendAudit(_ pane: UUID, _ event: String) throws {
        try lock()
        struct Entry: Encodable { var pane: UUID; var event: String; var at: Date }
        guard event.utf8.count <= 128 else { throw RelayQuotaWire.Invalid.payload }
        var data = try JSONEncoder().encode(Entry(pane: pane, event: event, at: Date()))
        data.append(10)
        let path = url.path + ".audit.jsonl"
        let fd = open(path, O_CREAT | O_APPEND | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size + Int64(data.count) <= 32 << 20,
              fchmod(fd, 0o600) == 0 else { throw POSIXError(.EIO) }
        // An interrupted append must not be joined to a new JSON event.
        // Preserve the evidence and stop; never silently truncate or replay.
        var last: UInt8 = 0
        guard metadata.st_size == 0 || pread(fd, &last, 1, metadata.st_size - 1) == 1,
              RelayQuotaWire.auditAppendable(size: metadata.st_size, last: metadata.st_size == 0 ? nil : last) else { throw POSIXError(.EIO) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        let parentFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard parentFD >= 0 else { throw POSIXError(.EIO) }
        defer { close(parentFD) }
        guard fsync(parentFD) == 0 else { throw POSIXError(.EIO) }
    }
    func load() throws -> RelayClaudeQuotaEngine.Disk {
        try lock()
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 1 << 20 else { throw RelayQuotaWire.Invalid.payload }
        return try RelayClaudeQuotaEngine.Disk.decode(Data(contentsOf: url))
    }
    func save(_ disk: RelayClaudeQuotaEngine.Disk) throws {
        try lock()
        let data = try JSONEncoder().encode(disk)
        _ = try RelayClaudeQuotaEngine.Disk.decode(data)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Class-B complete-unless-open protection permits creation while
        // locked, but refuses our subsequent reopen for fsync. Use the
        // directory's ordinary protection; mode 0600 remains explicit.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let fd = open(parent.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}
