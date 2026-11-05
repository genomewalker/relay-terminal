import Foundation
#if !SHEPHERD_STANDALONE
@testable import Relay
#endif

// Shared by native Swift Testing and the standalone swiftq runner. A failing
// property throws in release builds as well; no assertion is optimized away.
enum RelayShepherdChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ ok: @autoclosure () throws -> Bool, _ property: String) throws {
        if try !ok() { throw Failure(description: property) }
    }
    static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static func snapshot(_ state: RelayShepherdSnapshot.State = .busy, _ output: String = "one", prompt: String = "", jobs: [String: String] = [:]) -> RelayShepherdSnapshot {
        .init(paneID: id, host: "fake-host", state: state, output: output, promptID: prompt, jobs: jobs)
    }
    static var settings: RelayShepherdSettings { var s = RelayShepherdSettings(); s.enabled = true; s.stallSeconds = 60; return s }
    static func smoke() throws {
        let job = RelayShepherdExecSnapshot(id: "job", state: "exited", exitCode: 1, stdoutOffset: 0, stderrOffset: 0)
        try require(job.completionKind == "jobFailed", "failed exec results request attention")
        var e = RelayShepherdEngine()
        let s = settings
        try require(!s.permitsLegacyMonitoring(maintenance: true, haiku: true), "shepherd disables legacy automatic model/repair loops")
        func poll(_ value: RelayShepherdSnapshot, _ time: Double) -> [RelayShepherdReport] {
            e.poll(id: id, host: "fake-host", settings: s, paused: false, now: time) { value }
        }
        try require(poll(snapshot(), 0).count == 1, "SH2 every relevant transition is reported")
        try require(poll(snapshot(), 1).isEmpty, "SH1 unchanged state is not re-reported")
        try require(poll(snapshot(.busy, "two"), 2).count == 1, "SH2 relevant output is reported")
        try require(poll(snapshot(.waitingForUser, "approve?", prompt: "prompt-a"), 3).count == 1, "SH10 waiting prompt is reported")
        try require(poll(snapshot(.waitingForUser, "approve?", prompt: "prompt-b"), 4).count == 1, "a new prompt identity is significant")
        try require(poll(snapshot(), 5).count == 1, "SH29 a returning state is a new event occurrence")
        try require(poll(snapshot(), 64).isEmpty, "no early stall")
        try require(poll(snapshot(), 65).map(\.kind) == ["stall"], "SH9 stall is reported at threshold")
        try require(poll(snapshot(), 66).isEmpty, "SH9 one report per stall")
        try require(e.modelCalls == 0, "SH8 no model call for monitoring")
        let before = e.reads
        var opted = s; opted.excludedPanes = [id]
        _ = e.poll(id: id, host: "fake-host", settings: opted, paused: false, now: 70) { snapshot() }
        try require(e.reads == before, "SH12 opted-out panes are never read")
        opted = s; opted.excludedHosts = ["fake-host"]
        _ = e.poll(id: id, host: "fake-host", settings: opted, paused: false, now: 70) { snapshot() }
        try require(e.reads == before, "opted-out hosts are never read")
        _ = e.poll(id: id, host: "fake-host", settings: s, paused: true, now: 70) { snapshot() }
        try require(e.reads == before, "pause stops reads")
        try require(snapshot(.busy, "\u{1b}[?25lone\u{1b}[?25h").digest == snapshot().digest, "cursor controls are irrelevant")
        try require(snapshot(.busy, "⠋").digest == snapshot(.busy, "⠙").digest, "spinner-only change is irrelevant")
        try require(snapshot(.busy, "⠋ Thinking").digest == snapshot(.busy, "⠙ Thinking").digest, "leading spinner frame is irrelevant")
        try require(snapshot(.busy, "  code").digest != snapshot(.busy, "code").digest, "code indentation stays relevant")
        try require(snapshot(.busy, "12:00 new prompt").digest != snapshot(.busy, "12:01 new prompt").digest, "timestamps in text remain relevant")
        try require(snapshot(jobs: ["job-a": "running"]).digest != snapshot(jobs: ["job-a": "exited; exit=1"]).digest, "exit status changes digest")
        try require(snapshot().digest != snapshot(.failed).digest, "state changes digest")
        try require(snapshot(.busy, "one").digest != snapshot(.busy, "two").digest, "relevant content changes digest")
        try require(RelayShepherdSnapshot.normalize(String(repeating: "x", count: 1_000_000)).utf8.count <= 65_536, "bounded normalization")
        let unicode = RelayShepherdSnapshot.normalize(String(repeating: "⠋ \n👩🏽‍🔬", count: 20_000))
        try require(unicode.utf8.count <= 65_536 && RelayShepherdSnapshot.normalize(unicode) == unicode, "unicode normalization is bounded and idempotent")
    }
    static func budget() throws {
        var b = RelayShepherdModelBudget(), s = settings
        s.callsPerHour = 2; s.tokensPerHour = 10
        try require(!b.admit(tokens: 1, settings: s, paused: true, now: 0), "pause stops model")
        try require(b.admit(tokens: 6, settings: s, paused: false, now: 0), "budget below cap")
        try require(!b.admit(tokens: 5, settings: s, paused: false, now: 1), "SH7 token budget is never exceeded")
        try require(b.admit(tokens: 4, settings: s, paused: false, now: 1), "budget at exact token cap")
        try require(!b.admit(tokens: 0, settings: s, paused: false, now: 2), "SH7 call budget is never exceeded")
        try require(b.admit(tokens: 6, settings: s, paused: false, now: 3600), "rolling hour releases reservations")
        s.callsPerHour = 0
        try require(!b.admit(tokens: 0, settings: s, paused: false, now: 7200), "zero cap disables model calls")
    }
    static func boundedBudget() throws -> Int {
        var visits = 0
        struct RefBudget {
            var reservations: [(Double, Int)] = []
            var now = 0.0
            var paused = false
            var calls = 2
            var tokens = 10
        }
        func walk(_ budget: RelayShepherdModelBudget, _ ref: RefBudget, _ depth: Int) throws {
            guard depth < 4 else { return }
            for op in 0..<12 {
                var b = budget, r = ref, s = settings
                var cost = 0
                switch op {
                case 0..<4: cost = [0, 1, 10, 11][op]
                case 4: r.now += 3599
                case 5: r.now += 3600
                case 6: r.paused = true
                case 7: r.paused = false
                case 8: r.calls = 0
                case 9: r.calls = 2
                case 10: r.tokens = 0
                default: r.tokens = 10
                }
                s.callsPerHour = r.calls; s.tokensPerHour = r.tokens
                r.reservations.removeAll { r.now - $0.0 >= 3600 }
                let expected = !r.paused && r.reservations.count < r.calls && r.reservations.reduce(0, { $0 + $1.1 }) + cost <= r.tokens
                let allowed = b.admit(tokens: cost, settings: s, paused: r.paused, now: r.now)
                try require(allowed == expected, "bounded call/token cap and pause")
                if expected { r.reservations.append((r.now, cost)) }
                visits += 1
                try walk(b, r, depth + 1)
            }
        }
        try walk(RelayShepherdModelBudget(), RefBudget(), 0)
        return visits
    }
    static func authorization(catalog: [String]) throws -> Int {
        let expected: Set<String> = ["relay_tools", "relay_list_panes", "get_pane_health", "get_rotation_status", "relay_exec_status", "relay_read_agent_context", "relay_pane_message_receipt", "read_assistant_inbox", "relay_list_pane_links", "native_snapshot", "native_receipt"]
        var states = 0
        for tool in catalog + ["relay_update_settings", "relay_send_command", "relay_move_pane_account", "relay_install_relayd", "unknown_tool",
            "native_snapshot", "native_receipt", "native_action", "native_image", "native_launch", "native_resume",
            "set_capacity_pause", "request_capacity_action"] {
            for origin in RelayShepherdToolPolicy.Origin.allCases {
                for enabled in [false, true] {
                    let allowed = RelayShepherdToolPolicy.allows(tool, enabled: enabled, origin: origin)
                    try require(allowed == (!enabled || expected.contains(tool)), "SH3/4/5 allowlist: \(tool) \(origin) mode=\(enabled)")
                    states += 1
                }
            }
        }
        for origin in RelayShepherdToolPolicy.Origin.allCases {
            for chosen in [nil, id, other] {
                for target in [nil, id, other] {
                    for report in [false, true] {
                        let allowed = RelayShepherdToolPolicy.allows("relay_message_pane", enabled: true, origin: origin, chosenPane: chosen, target: target, report: report)
                        try require(allowed == (origin == .shepherd && report && chosen != nil && chosen == target), "SH11 only chosen pane receives report")
                        states += 1
                    }
                }
            }
        }
        return states
    }

    // State space is factored by pane: decision state contains no cross-pane
    // state. Every length<=4 multi-pane trace projects to these per-pane traces.
    // All ordered two-actor pairs below additionally test the separation in the
    // real engine, for each of the three pane identities. Shared controls are
    // included in each projection, so pause/time/budget changes are not omitted.
    struct Ref {
        var state: RelayShepherdSnapshot.State = .busy
        var output = "one"
        var prompt = ""
        var paused = false
        var excluded = false
        var capped = false
        var time = 0.0
        var digest = ""
        var changed = 0.0
        var stalled = false
    }
    // 6 state operations; 3 output operations (unchanged, noise, relevant);
    // 3 times (before, at, beyond stall); pause/opt-out/budget on and off; poll.
    static let operationCount = 19
    static func apply(_ op: Int, id: UUID, engine: inout RelayShepherdEngine, ref: inout Ref) throws {
        switch op {
        case 0..<6: ref.state = RelayShepherdSnapshot.State.allCases[op]; ref.prompt = ref.state == .waitingForUser ? "question" : ""
        case 6: break
        case 7: ref.output = ref.output == "one" ? "\u{1b}[?25lone\u{1b}[?25h" : ref.output
        case 8: ref.output = "new prompt / output"
        case 9: ref.time += 59
        case 10: ref.time += 60
        case 11: ref.time += 61
        case 12: ref.paused = true
        case 13: ref.paused = false
        case 14: ref.excluded = true
        case 15: ref.excluded = false
        case 16: ref.capped = true
        case 17: ref.capped = false
        default: break
        }
        var s = settings
        s.callsPerHour = ref.capped ? 0 : 60; s.tokensPerHour = ref.capped ? 0 : 200_000
        if ref.excluded { s.excludedPanes.insert(id) }
        let value = RelayShepherdSnapshot(paneID: id, host: "fake-host", state: ref.state, output: ref.output, promptID: ref.prompt, jobs: [:])
        // Oracle uses normalized fields rather than the production hash.
        let canonicalOutput = ref.output == "\u{1b}[?25lone\u{1b}[?25h" ? "one" : ref.output
        let canonical = ref.state.rawValue + "|" + canonicalOutput + "|" + ref.prompt
        var expected: [String] = []
        if !ref.paused && !ref.excluded {
            if ref.digest != canonical {
                ref.digest = canonical; ref.changed = ref.time; ref.stalled = false
                expected = [ref.state.rawValue]
            } else if ref.state == .busy && !ref.stalled && ref.time - ref.changed >= 60 {
                ref.stalled = true; expected = ["stall"]
            }
        }
        let before = engine.reads
        let actual = engine.poll(id: id, host: "fake-host", settings: s, paused: ref.paused, now: ref.time) { value }
        try require(actual.map(\.kind) == expected, "bounded report/no-report op \(op), expected \(expected), actual \(actual.map(\.kind))")
        try require(engine.modelCalls == 0, "bounded no polling-triggered model calls")
        try require(engine.reads == before + (ref.paused || ref.excluded ? 0 : 1), "bounded pause and opt-out before read")
    }
    static func bounded() throws -> Int {
        var visits = 0
        func explore(_ e: RelayShepherdEngine, _ r: Ref, _ depth: Int) throws {
            guard depth < 4 else { return }
            for op in 0..<operationCount {
                var e = e, r = r
                try apply(op, id: id, engine: &e, ref: &r)
                visits += 1
                try explore(e, r, depth + 1)
            }
        }
        try explore(RelayShepherdEngine(), Ref(), 0)
        let ids = [id, other, UUID(uuidString: "00000000-0000-4000-8000-000000000003")!]
        // Two-actor commutation checks on every pair of distinct panes,
        // every ordered operation pair and six two-operation schedules.
        // Per-pane length-4 projections above enumerate all 19^4 choices.
        let schedules = [[0,0,1,1], [0,1,0,1], [0,1,1,0], [1,0,0,1], [1,0,1,0], [1,1,0,0]]
        for first in 0..<3 {
            for second in (first+1)..<3 {
                for a in 0..<operationCount {
                    for b in 0..<operationCount {
                        // Operations on disjoint pane state commute. Ordered
                        // adjacent pairs are sufficient to commute every
                        // length-4 schedule to the checked projections.
                        var engine = RelayShepherdEngine(), r1 = Ref(), r2 = Ref()
                        try apply(a, id: ids[first], engine: &engine, ref: &r1)
                        try apply(b, id: ids[second], engine: &engine, ref: &r2)
                        visits += 2
                        for schedule in schedules {
                            var engine = RelayShepherdEngine(), refs = [Ref(), Ref()]
                            for actor in schedule {
                                var ref = refs[actor]
                                try apply(actor == 0 ? a : b, id: ids[actor == 0 ? first : second], engine: &engine, ref: &ref)
                                refs[actor] = ref; visits += 1
                            }
                        }
                    }
                }
            }
        }
        return visits
    }

    struct Random {
        var x: UInt64 = 0x5348455048455244
        mutating func next(_ n: Int) -> Int { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int(x >> 32) % n }
    }
    static func fuzz(iterations: Int = 25_000, log: (String) -> Void = { print($0) }) throws {
        let settingsData = try JSONEncoder().encode(settings)
        let snapshotData = try JSONEncoder().encode(snapshot())
        let execData = Data(#"{"request_id":"rpc-seed","result":{"job":{"job_id":"job-seed","state":"exited","exit_code":0},"stdout_offset":12,"stderr_offset":0}}"#.utf8)
        let seedRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ShepherdSeeds")
        let committed = try ["settings", "pane", "exec"].map { name in
            Data(try String(contentsOf: seedRoot.appendingPathComponent(name + ".json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        let seeds = [settingsData, snapshotData, execData] + committed
        for (index, seed) in seeds.enumerated() {
            for length in 0..<seed.count { try require(!accept(seed.prefix(length), index % 3), "reject truncated seed \(index) at \(length)") }
            var obj = try JSONSerialization.jsonObject(with: seed) as! [String: Any]; obj["unexpected"] = true
            try require(!accept(try JSONSerialization.data(withJSONObject: obj), index % 3), "reject extra key seed \(index)")
        }
        var nested = try JSONSerialization.jsonObject(with: execData) as! [String: Any]
        var result = nested["result"] as! [String: Any]; result["surprise"] = 1; nested["result"] = result
        try require(!accept(try JSONSerialization.data(withJSONObject: nested), 2), "reject extra exec result key")
        result.removeValue(forKey: "surprise")
        var job = result["job"] as! [String: Any]; job["surprise"] = 1; result["job"] = job; nested["result"] = result
        try require(!accept(try JSONSerialization.data(withJSONObject: nested), 2), "reject extra exec job key")
        job.removeValue(forKey: "surprise"); job["exit_code"] = true; result["job"] = job; nested["result"] = result
        try require(!accept(try JSONSerialization.data(withJSONObject: nested), 2), "reject boolean exit code")
        try require(try RelayShepherdSettings.decode(settingsData) == settings, "settings round trip")
        try require(try RelayShepherdSnapshot.decode(snapshotData).paneID == id, "pane ID round trips exactly")
        try require(try RelayShepherdExecSnapshot.decode(execData).id == "job-seed", "job ID round trips exactly")
        var oversized = settings; oversized.interval = 9
        try require(!accept(try JSONEncoder().encode(oversized), 0), "settings bounds enforced")
        var random = Random()
        let start = Date(); var last = start; var batch = 0
        for i in 0..<iterations {
            let selection = random.next(seeds.count), index = selection % 3, seed = seeds[selection]
            var bytes = Array(seed)
            switch random.next(5) {
            case 0: bytes = (0..<random.next(512)).map { _ in UInt8(random.next(256)) }
            case 1: bytes.removeSubrange(random.next(bytes.count)..<bytes.count)
            case 2: bytes[random.next(bytes.count)] = UInt8(random.next(256))
            case 3: bytes.insert(UInt8(random.next(256)), at: random.next(bytes.count))
            default: break
            }
            let data = Data(bytes)
            switch index {
            case 0:
                if let s = try? RelayShepherdSettings.decode(data) {
                    try require(s == s.bounded, "fuzz settings stay bounded")
                    try require(try RelayShepherdSettings.decode(JSONEncoder().encode(s)) == s, "fuzz settings round trip")
                }
            case 1:
                if let s = try? RelayShepherdSnapshot.decode(data) {
                    let decoded = try RelayShepherdSnapshot.decode(JSONEncoder().encode(s))
                    try require(decoded == s && decoded.digest == s.digest, "fuzz pane/report digest round trip")
                    let n = RelayShepherdSnapshot.normalize(s.output)
                    try require(RelayShepherdSnapshot.normalize(n) == n && n.utf8.count <= 65_536, "fuzz normalization idempotent and bounded")
                    try require(s.digest.count == 64, "fuzz digest bounded")
                }
            default:
                if let s = try? RelayShepherdExecSnapshot.decode(data) {
                    try require(!s.id.isEmpty && s.id.utf8.count <= 128 && s.stdoutOffset >= 0 && s.stderrOffset >= 0, "fuzz exec IDs/offsets bounded")
                }
            }
            batch += 1
            if (i + 1) % 5000 == 0 {
                let now = Date(), elapsed = now.timeIntervalSince(last)
                log("FUZZ execs=\(i + 1) elapsed=\(now.timeIntervalSince(start)) batch_execs_per_sec=\(Double(batch)/max(elapsed, 0.000001))")
                last = now; batch = 0
            }
        }
    }
    static func accept(_ data: Data, _ index: Int) -> Bool {
        switch index {
        case 0: return (try? RelayShepherdSettings.decode(data)) != nil
        case 1: return (try? RelayShepherdSnapshot.decode(data)) != nil
        default: return (try? RelayShepherdExecSnapshot.decode(data)) != nil
        }
    }
}
