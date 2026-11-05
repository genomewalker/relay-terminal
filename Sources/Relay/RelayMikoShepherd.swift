import CryptoKit
import CoreFoundation
import Foundation

// Deliberately independent of the model, transport and UI. All clocks and reads
// enter as values/closures so the decision code is exercised without accounts.
struct RelayShepherdSettings: Codable, Equatable, Sendable {
    enum Model: String, Codable, CaseIterable, Sendable { case haiku = "claude-haiku-5-5" }
    var enabled = false
    var model: Model = .haiku
    var interval = 30
    var stallSeconds = 600
    var callsPerHour = 60
    var tokensPerHour = 200_000
    var excludedPanes: Set<UUID> = []
    var excludedHosts: Set<String> = []
    // UI reporting is always enabled. The separate push ledger uses the
    // explicitly accepted existing Miko owner-submitted channel (Option C).
    var bounded: Self {
        var x = self
        x.interval = min(300, max(10, interval))
        x.stallSeconds = min(7200, max(60, stallSeconds))
        x.callsPerHour = min(600, max(0, callsPerHour))
        x.tokensPerHour = min(2_000_000, max(0, tokensPerHour))
        return x
    }
    func permitsLegacyMonitoring(maintenance: Bool, haiku: Bool) -> Bool {
        !enabled && (maintenance || haiku)
    }
    func watches(_ id: UUID, host: String) -> Bool {
        enabled && !excludedPanes.contains(id) && !excludedHosts.contains(host)
    }
    static func decode(_ data: Data) throws -> Self {
        try RelayShepherdWire.keys(data, allowed: ["enabled", "model", "interval", "stallSeconds", "callsPerHour", "tokensPerHour", "excludedPanes", "excludedHosts"], limit: 65_536)
        let x = try JSONDecoder().decode(Self.self, from: data)
        guard x == x.bounded, x.excludedPanes.count <= 512, x.excludedHosts.count <= 128,
              x.excludedHosts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw RelayShepherdWire.invalid }
        return x
    }
}

enum RelayShepherdWire {
    static var invalid: NSError { NSError(domain: "RelayShepherd", code: 1) }
    static func keys(_ data: Data, allowed: Set<String>, limit: Int) throws {
        guard data.count <= limit, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys).isSubset(of: allowed) else { throw invalid }
    }
}

struct RelayShepherdSnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, CaseIterable, Sendable {
        case idle, busy, waitingForUser, finishedOK, failed, ended
    }
    let paneID: UUID
    let host: String
    let state: State
    let output: String
    let promptID: String
    let jobs: [String: String]
    static func decode(_ data: Data) throws -> Self {
        try RelayShepherdWire.keys(data, allowed: ["paneID", "host", "state", "output", "promptID", "jobs"], limit: 131_072)
        let x = try JSONDecoder().decode(Self.self, from: data)
        guard x.host.utf8.count <= 256, x.output.utf8.count <= 65_536, x.promptID.utf8.count <= 256,
              x.jobs.count <= 128, x.jobs.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 256 }) else { throw RelayShepherdWire.invalid }
        return x
    }
    // Only terminal control sequences and standalone spinner glyphs are noise.
    // Timestamps embedded in content remain significant (including deadlines).
    static func normalize(_ text: String) -> String {
        var bytes = Data(text.utf8.prefix(65_536))
        // A Swift String is valid UTF-8; at most three trailing bytes need
        // trimming when the byte limit cuts through a scalar.
        while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        let bounded = String(data: bytes, encoding: .utf8) ?? ""
        return bounded.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let s = line.replacingOccurrences(of: "[ \t\r]+$", with: "", options: .regularExpression)
                if s.count == 1, "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(s) { return "*" }
                return s.replacingOccurrences(of: "^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][ \t]+", with: "* ", options: .regularExpression)
            }.joined(separator: "\n")
    }
    var digest: String {
        // Length framed canonical JSON avoids delimiter collisions and keeps
        // exact pane, host, prompt and exec identities in the report digest.
        let fields: [String] = [paneID.uuidString, host, state.rawValue, Self.normalize(output), promptID] +
            jobs.keys.sorted().flatMap { [$0, jobs[$0]!] }
        return Self.hash((try? JSONEncoder().encode(fields)) ?? Data())
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct RelayShepherdReport: Equatable, Sendable {
    let paneID: UUID
    let host: String
    let kind: String
    let digest: String
    let text: String
    // Stable when this event is replayed; new for a later transition to the same state.
    var occurrenceID: String = UUID().uuidString.lowercased()
}

struct RelayShepherdEngine {
    private struct Observation {
        var digest: String
        var changedAt: TimeInterval
        var stalled = false
    }
    private var observations: [UUID: Observation] = [:]
    private(set) var reads = 0
    // Templates never invoke a model. Interactive Miko calls have their own
    // shared rolling-hour reservation below, in addition to host accounting.
    private(set) var modelCalls = 0
    mutating func poll(id: UUID, host: String, settings: RelayShepherdSettings, paused: Bool,
                       now: TimeInterval, read: () -> RelayShepherdSnapshot?) -> [RelayShepherdReport] {
        guard !paused, settings.watches(id, host: host), now.isFinite else { return [] }
        reads += 1
        guard let s = read(), s.paneID == id, s.host == host else { return [] }
        let digest = s.digest
        var previous = observations[id] ?? Observation(digest: "", changedAt: now)
        var reports: [RelayShepherdReport] = []
        if previous.digest != digest {
            previous.digest = digest; previous.changedAt = now; previous.stalled = false
            do {
                reports.append(.init(paneID: id, host: host, kind: s.state.rawValue, digest: digest,
                    text: "\(host) · \(id.uuidString.lowercased()) · \(s.state.rawValue)" +
                        (s.promptID.isEmpty ? "" : " · prompt \(String(s.promptID.prefix(160)))") +
                        (s.jobs.isEmpty ? "" : " · " + s.jobs.keys.sorted().prefix(16).map { "\($0): \(s.jobs[$0]!)" }.joined(separator: ", ")) +
                        "\nUntrusted viewport excerpt: " + String(decoding: RelayShepherdSnapshot.normalize(s.output).utf8.prefix(800), as: UTF8.self)))
            }
        } else if s.state == .busy, !previous.stalled, now - previous.changedAt >= Double(settings.bounded.stallSeconds) {
            previous.stalled = true
            reports.append(.init(paneID: id, host: host, kind: "stall", digest: digest + ":stall:\(previous.changedAt)",
                text: "\(host) · \(id.uuidString.lowercased()) · no relevant output for \(settings.bounded.stallSeconds) seconds"))
        }
        observations[id] = previous
        return reports
    }
}

struct RelayShepherdModelBudget {
    private var reservations: [(TimeInterval, Int)] = []
    private(set) var capNoted = false
    mutating func admit(tokens: Int, settings: RelayShepherdSettings, paused: Bool, now: TimeInterval) -> Bool {
        guard !paused, now.isFinite, tokens >= 0 else { return false }
        reservations.removeAll { now - $0.0 >= 3600 }
        guard reservations.count < settings.bounded.callsPerHour,
              tokens <= settings.bounded.tokensPerHour - reservations.reduce(0, { $0 + $1.1 }) else {
            capNoted = true; return false
        }
        reservations.append((now, tokens)); return true
    }
}

// Layered before parity policy AND immediately before dispatch after awaits.
// No origin (including the user) can widen this list while shepherd mode is on.
enum RelayShepherdToolPolicy {
    enum Origin: CaseIterable { case shepherd, user, paneContentDerived }
    static let reads: Set<String> = ["relay_tools", "relay_list_panes", "get_pane_health", "get_rotation_status",
        "relay_exec_status", "relay_read_agent_context", "relay_pane_message_receipt", "read_assistant_inbox", "relay_list_pane_links",
        "native_snapshot", "native_receipt"]
    static func allows(_ tool: String, enabled: Bool, origin: Origin, chosenPane: UUID? = nil,
                       target: UUID? = nil, report: Bool = false) -> Bool {
        guard enabled else { return true }
        if tool == "relay_message_pane" { return report && origin == .shepherd && chosenPane != nil && target == chosenPane }
        return reads.contains(tool)
    }
}

struct RelayShepherdExecSnapshot: Equatable, Sendable {
    let id: String
    let state: String
    let exitCode: Int?
    let stdoutOffset: Int
    let stderrOffset: Int
    var finished: Bool { ["exited", "failed", "unknown_after_daemon_restart"].contains(state) }
    var completionKind: String? {
        guard finished else { return nil }
        if state == "unknown_after_daemon_restart" { return "jobNeedsReview" }
        return state == "exited" && exitCode == 0 ? "jobFinished" : "jobFailed"
    }
    var summary: String { "\(state); exit=\(exitCode.map(String.init) ?? "pending"); stdout=\(stdoutOffset); stderr=\(stderrOffset)" }
    static func decode(_ data: Data) throws -> Self {
        try RelayShepherdWire.keys(data, allowed: ["request_id", "result", "error"], limit: 262_144)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let requestID = root["request_id"] as? String, !requestID.isEmpty, requestID.utf8.count <= 128,
              let result = root["result"] as? [String: Any],
              Set(result.keys).isSubset(of: ["job", "process_state", "stdout", "stderr", "stdout_offset", "stderr_offset"]),
              let job = result["job"] as? [String: Any],
              Set(job.keys).isSubset(of: ["job_id", "fingerprint", "kind", "state", "pid", "process_start", "exit_code", "error", "successor", "created_at", "updated_at", "ledger"]),
              let id = job["job_id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let state = job["state"] as? String,
              ["running", "starting", "exited", "failed", "unknown_after_daemon_restart"].contains(state),
              let out = result["stdout_offset"] as? NSNumber, CFGetTypeID(out) != CFBooleanGetTypeID(),
              let err = result["stderr_offset"] as? NSNumber, CFGetTypeID(err) != CFBooleanGetTypeID(),
              out.doubleValue >= 0, err.doubleValue >= 0,
              out.doubleValue <= Double(Int.max / 2), err.doubleValue <= Double(Int.max / 2),
              out.doubleValue.rounded() == out.doubleValue, err.doubleValue.rounded() == err.doubleValue else { throw RelayShepherdWire.invalid }
        let exit = job["exit_code"] as? NSNumber
        if let exit { guard CFGetTypeID(exit) != CFBooleanGetTypeID(), exit.doubleValue.rounded() == exit.doubleValue,
                           abs(exit.doubleValue) <= 2_147_483_647 else { throw RelayShepherdWire.invalid } }
        if job["exit_code"] != nil && exit == nil { throw RelayShepherdWire.invalid }
        return .init(id: id, state: state, exitCode: exit?.intValue, stdoutOffset: out.intValue, stderrOffset: err.intValue)
    }
}
