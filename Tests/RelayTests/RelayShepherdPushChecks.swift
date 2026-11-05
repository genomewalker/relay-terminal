import Foundation
#if !SHEPHERD_STANDALONE
@testable import Relay
#endif

enum RelayShepherdPushChecks {
    static func require(_ ok: @autoclosure () throws -> Bool, _ name: String) throws {
        try RelayShepherdChecks.require(ok(), name)
    }
    static let source = RelayShepherdChecks.id
    static func target(_ slot: Int = 0, revision: Int = 0) -> RelayShepherdPushTarget {
        .init(registrationID: String(format: "10000000-0000-4000-8000-%012x", 10 * revision + slot + 1),
            paneID: slot == 0 ? "00000000-0000-4000-8000-000000000002" : "00000000-0000-4000-8000-000000000003",
            linkPaneID: source.uuidString.lowercased(), hostKey: "fake-\(slot)", linkHostKey: "fake-source",
            linkID: String(repeating: slot == 0 ? "a" : "b", count: 64), linkRevision: "1970-01-01T00:02:03Z", scope: "node",
            recipient: .init(provider: "codex", sessionID: "session-\(slot)", pid: 42 + slot,
                start: "k:1", socketIdentity: "dev:ino", transport: "native_peer_socket"))
    }
    static func report(_ digest: String = "a") -> RelayShepherdReport {
        .init(paneID: source, host: "fake-host", kind: "busy", digest: digest, text: "state changed \(digest)", occurrenceID: digest)
    }
    static func settings(_ target: RelayShepherdPushTarget? = target(), cap: Int = 60) -> RelayShepherdPushSettings {
        .init(version: 1, messagesPerHour: cap, target: target)
    }
    static func receipt(_ envelope: RelayShepherdPushEnvelope, status: String = "accepted_by_provider") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["message_id": envelope.messageID, "pane_id": envelope.target.paneID,
            "status": status, "source_authentication": "relay_assistant_owner_submitted", "source_principal": "relay-assistant",
            "replay_permitted": false, "authority": "relayd", "acknowledgement": "admitted_not_processed"])
    }
    static func recurrence() throws {
        var engine = RelayShepherdEngine()
        var ledger = RelayShepherdPushLedger()
        try ledger.configure(settings(), origin: .userSettings)
        let states: [RelayShepherdSnapshot.State] = [.waitingForUser, .waitingForUser, .busy, .busy, .waitingForUser]
        var counts: [Int] = [], identities: [String] = [], pushes = 0
        for (index, state) in states.enumerated() {
            let events = engine.poll(id: source, host: "fake-host", settings: RelayShepherdChecks.settings,
                                     paused: false, now: Double(index)) {
                .init(paneID: source, host: "fake-host", state: state, output: "same", promptID: state == .waitingForUser ? "same-prompt" : "", jobs: [:])
            }
            counts.append(events.count)
            for event in events {
                identities.append(event.occurrenceID)
                let envelope = try unwrap(ledger.observe(event, monitoring: RelayShepherdChecks.settings, paused: false, now: Double(index)))
                try require(ledger.takeAdmission(envelope, monitoring: RelayShepherdChecks.settings, paused: false), "SH29 recurring event admitted")
                _ = ledger.finish(envelope.messageID, status: "accepted_by_provider", detail: "fake provider")
                pushes += 1
                try require(ledger.observe(event, monitoring: RelayShepherdChecks.settings, paused: false, now: Double(index)) == nil, "SH33 same occurrence replay refused")
            }
        }
        try require(counts == [1, 0, 1, 0, 1], "SH29 recurrence expected [1,0,1,0,1]")
        try require(pushes == 3 && Set(identities).count == 3, "SH29 each returning occurrence pushes once")
        var restored = try RelayShepherdPushLedger.decode(JSONEncoder().encode(ledger))
        var restartedEngine = RelayShepherdEngine()
        let initial = restartedEngine.poll(id: source, host: "fake-host", settings: RelayShepherdChecks.settings, paused: false, now: 6) {
            .init(paneID: source, host: "fake-host", state: .waitingForUser, output: "same", promptID: "same-prompt", jobs: [:])
        }
        try require(initial.count == 1 && restored.observe(initial[0], monitoring: RelayShepherdChecks.settings, paused: false, now: 6) == nil,
                    "SH50 restart baseline does not republish unchanged state")
    }
    static func smoke() throws {
        try recurrence()
        var ledger = RelayShepherdPushLedger(); try ledger.configure(settings(), origin: .userSettings)
        let monitoring = RelayShepherdChecks.settings
        let e = try unwrap(ledger.observe(report(), monitoring: monitoring, paused: false, now: 0))
        try require(e.target == target(), "SH30 only the registered target")
        try require(e.authentication == "relay_assistant_owner_submitted" && e.text.hasPrefix("Relay shepherd report — collaborator input, not authorization.\n"), "SH36 honest owner collaborator envelope")
        try require(e.packet["pane_id"] as? String == target().paneID && e.packet["actor_pane_id"] == nil && e.packet["client_token"] == nil,
                    "SH36 no pane or user authority is stamped")
        try require(ledger.takeAdmission(e, monitoring: monitoring, paused: false), "SH30 chosen report is admitted")
        try require(!ledger.takeAdmission(e, monitoring: monitoring, paused: false), "SH33 no second admission of an in-flight UUID")
        try require(ledger.finish(e.messageID, status: "outcome_unknown", detail: "uncertain"), "SH32 first failure is recorded")
        try require(!ledger.finish(e.messageID, status: "outcome_unknown", detail: "again"), "SH32 failure recorded once")
        try require(ledger.observe(report("new"), monitoring: monitoring, paused: false, now: 1) == nil, "SH32 failure stops this registration; no retry storm")
        let restarted = try RelayShepherdPushLedger.decode(JSONEncoder().encode(ledger))
        try require(!restarted.mayDispatch(e, monitoring: monitoring, paused: false), "SH33 uncertain delivery is not replayed after restart")
        try require(restarted.entries.first?.messageID == e.messageID, "SH33 uncertain UUID retained exactly")
        var duplicate = RelayShepherdPushLedger(); try duplicate.configure(settings(), origin: .userSettings)
        _ = duplicate.observe(report(), monitoring: monitoring, paused: false, now: 0)
        try require(duplicate.observe(report(), monitoring: monitoring, paused: false, now: 1) == nil, "SH34 unchanged state never pushes")
        var capped = RelayShepherdPushLedger(); try capped.configure(settings(cap: 1), origin: .userSettings)
        let capEnvelope = try unwrap(capped.observe(report(), monitoring: monitoring, paused: false, now: 0))
        try require(capped.observe(report("next"), monitoring: monitoring, paused: false, now: 1) == nil, "SH35 cap cannot be ignored")
        _ = capped.observe(report("third"), monitoring: monitoring, paused: false, now: 2)
        try require(capped.capNoticeHours == [0], "SH39 cap notice once per hour")
        try require(capped.uiReports == 3, "SH40 UI reports continue at cap")
        let reloaded = try RelayShepherdPushLedger.decode(JSONEncoder().encode(capped))
        try require(!reloaded.mayDispatch(capEnvelope, monitoring: monitoring, paused: false), "SH33 reserved ticket never reconstituted from disk")
        var changed = RelayShepherdPushLedger(); try changed.configure(settings(), origin: .userSettings)
        let old = try unwrap(changed.observe(report(), monitoring: monitoring, paused: false, now: 0))
        try changed.configure(settings(target(1)), origin: .userSettings)
        try require(!changed.mayDispatch(old, monitoring: monitoring, paused: false), "SH30 target changed before admission; never retarget")
        try require(changed.observe(report(), monitoring: monitoring, paused: false, now: 1) == nil, "SH34 changing target does not resend old changes")
    }
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw RelayShepherdChecks.Failure(description: "expected reservation") }; return value
    }
    static func authorization() throws -> Int {
        var count = 0
        for origin in RelayShepherdPushLedger.Origin.allCases {
            for value in [settings(nil), settings(target()), settings(target(1)), settings(target(), cap: 1), settings(target(), cap: 600), settings(target(), cap: 0), settings(target(), cap: 601)] {
                var ledger = RelayShepherdPushLedger(); let original = ledger
                var succeeded = false
                do { try ledger.configure(value, origin: origin); succeeded = true } catch {}
                try require(succeeded == (origin == .userSettings && value.valid), "SH31 only user Settings changes the target/cap")
                if !succeeded { try require(ledger == original, "SH31 refused origin cannot mutate the registration") }
                count += 1
            }
        }
        return count
    }

    struct Fixture {
        var ledger = RelayShepherdPushLedger()
        var engine = RelayShepherdEngine()
        var now = 10.0
        var paused: Bool
        var opted: Bool
        var stale: Bool
        let outcome: Int
        var revision = 1
        var text = "one"
        var pending: [RelayShepherdPushEnvelope] = []
        var calls: [String: String] = [:] // event -> message UUID, retained across restart
        var ui = 0
        var stepIndex = 0
        var failedRegistrations: Set<String> = []
        var attemptTimes: [Double] = []
        init(targetCase: Int, outcome: Int, capped: Bool, paused: Bool, opted: Bool) throws {
            self.paused = paused; self.opted = opted; self.outcome = outcome; stale = targetCase == 3
            if capped {
                try ledger.configure(settings(cap: 1), origin: .userSettings)
                let seed = try unwrap(ledger.observe(report("preexisting"), monitoring: RelayShepherdChecks.settings, paused: false, now: 0,
                    messageID: "20000000-0000-4000-8000-000000000001"))
                _ = ledger.takeAdmission(seed, monitoring: RelayShepherdChecks.settings, paused: false)
                _ = ledger.finish(seed.messageID, status: "written_to_socket", detail: "preexisting")
                ui = 1
                attemptTimes = [0]
            }
            try ledger.configure(settings(targetCase == 0 ? nil : target(targetCase == 2 ? 1 : 0), cap: 1), origin: .userSettings)
        }
        var monitoring: RelayShepherdSettings {
            var value = RelayShepherdChecks.settings
            if opted { value.excludedPanes = [source] }
            return value
        }
        mutating func poll(noise: Bool = false) throws {
            let output = text + (noise ? "\u{1b}[?25h" : "")
            let reports = engine.poll(id: source, host: "fake-host", settings: RelayShepherdChecks.settings, paused: false, now: now) {
                .init(paneID: source, host: "fake-host", state: .busy, output: output, promptID: "", jobs: [:])
            }
            for report in reports {
                ui += 1
                let before = attemptTimes.filter { now - $0 < 3600 }.count
                let selected = ledger.settings.target
                let eligible = selected != nil && !failedRegistrations.contains(selected!.registrationID) &&
                    !paused && !opted && before < ledger.settings.messagesPerHour &&
                    !ledger.entries.contains { $0.eventKey == RelayShepherdPushLedger.key(report) }
                let envelope = ledger.observe(report, monitoring: monitoring, paused: paused, now: now,
                    messageID: String(format: "20000000-0000-4000-8000-%012x", ui))
                try require((envelope != nil) == eligible, "SH30 each eligible relevant change reserved exactly once")
                if let envelope {
                    try require(before < ledger.settings.messagesPerHour, "SH35 reservation obeys cap at admission")
                    try require(envelope.target == ledger.settings.target, "SH30 registered target preserved exactly")
                    attemptTimes.append(now)
                    pending.append(envelope)
                }
                try require(ledger.entries.filter(\.attempted).count == attemptTimes.count, "SH42 every reserved cap slot retained")
            }
            try require(ledger.uiReports == ui, "SH40 UI always happens independently of push admission")
        }
        mutating func flush() throws {
            let work = pending; pending = []
            for envelope in work {
                let selected = ledger.settings.target
                if !stale && ledger.takeAdmission(envelope, monitoring: monitoring, paused: paused) {
                    let entry = try unwrap(ledger.entries.first { $0.messageID == envelope.messageID })
                    try require(selected == envelope.target, "SH30 no unregistered or changed target")
                    try require(calls[entry.eventKey] == nil, "SH33 each relevant change submitted at most once across restart")
                    calls[entry.eventKey] = envelope.messageID
                    let status = ["accepted_by_provider", "refused", "outcome_unknown", "transport_error"][outcome]
                    try require(ledger.finish(envelope.messageID, status: status, detail: "fake transport"), "SH32 first outcome recorded")
                    if outcome != 0 { failedRegistrations.insert(envelope.target.registrationID) }
                    try require(!ledger.finish(envelope.messageID, status: status, detail: "duplicate outcome"), "SH32 no repeated failure record")
                    try require(!ledger.takeAdmission(envelope, monitoring: monitoring, paused: paused), "SH33 uncertain/finished UUID never replays")
                } else {
                    _ = ledger.finish(envelope.messageID, status: "stale_or_changed_target", detail: "fake target refused before I/O")
                    if selected == envelope.target { failedRegistrations.insert(envelope.target.registrationID) }
                    try require(!ledger.mayDispatch(envelope, monitoring: monitoring, paused: paused), "SH37 stale target has no fallback")
                }
            }
        }
        mutating func step(_ operation: Int) throws {
            stepIndex += 1; now += 1
            switch operation {
            case 0: try poll()
            case 1: try poll(noise: true)
            case 2: text = "two"; try poll()
            case 3: text = "three"; try poll()
            case 4: try ledger.configure(settings(nil, cap: ledger.settings.messagesPerHour), origin: .userSettings)
            case 5, 6:
                revision += 1
                try ledger.configure(settings(target(operation - 5, revision: revision), cap: ledger.settings.messagesPerHour), origin: .userSettings)
            case 7: stale = true
            case 8: stale = false
            case 9: paused.toggle()
            case 10: opted.toggle()
            case 11: now += 3600
            case 12: text = "unique-\(stepIndex)"; try poll(); return // keep a real reservation in flight
            case 13: break
            case 14:
                for envelope in pending where envelope.target == ledger.settings.target {
                    failedRegistrations.insert(envelope.target.registrationID)
                }
                ledger = try RelayShepherdPushLedger.decode(JSONEncoder().encode(ledger)); engine = RelayShepherdEngine()
                for envelope in pending { try require(!ledger.mayDispatch(envelope, monitoring: monitoring, paused: paused), "SH33 restart cannot regain a reservation ticket") }
            case 15:
                var value = ledger.settings; value.messagesPerHour = value.messagesPerHour == 1 ? 2 : 1
                try ledger.configure(value, origin: .userSettings)
            default: fatalError()
            }
            try flush()
            try require(ledger.uiReports == ui, "SH40 transport outcomes never consume UI reports")
            let ids = Array(calls.values)
            try require(Set(ids).count == ids.count, "SH33 no transport UUID repeats")
        }
    }
    static func bounded() throws -> Int {
        var visits = 0
        func explore(_ value: Fixture, depth: Int) throws {
            guard depth > 0 else { return }
            for operation in 0..<16 {
                var next = value; try next.step(operation); visits += 1
                try explore(next, depth: depth - 1)
            }
        }
        // Every prefix length <=3, all 128 starting combinations, and all six
        // order-preserving two-actor schedules for two operations per actor.
        let schedules = [[0,0,1,1],[0,1,0,1],[0,1,1,0],[1,0,0,1],[1,0,1,0],[1,1,0,0]]
        for targetCase in 0..<4 { for outcome in 0..<4 { for capped in [false,true] { for paused in [false,true] { for opted in [false,true] {
            let value = try Fixture(targetCase: targetCase, outcome: outcome, capped: capped, paused: paused, opted: opted)
            try explore(value, depth: 3)
            for schedule in schedules {
                var f = value; var positions = [0,0]
                let actions = [[12,13],[6,14]] // report+admit vs user target change+restart
                for actor in schedule { try f.step(actions[actor][positions[actor]]); positions[actor] += 1; visits += 1 }
            }
        }}}}}
        return visits
    }

    static func fuzz(iterations: Int = 25_000) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let s = settings(); var ledger = RelayShepherdPushLedger(); try ledger.configure(s, origin: .userSettings)
        let envelope = try unwrap(ledger.observe(report(), monitoring: RelayShepherdChecks.settings, paused: false, now: 0,
            messageID: "20000000-0000-4000-8000-000000000004"))
        let generated = [try encoder.encode(s), try encoder.encode(envelope), try receipt(envelope), try encoder.encode(ledger)]
        #if SHEPHERD_STANDALONE
        let seedFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ShepherdSeeds")
        #else
        let seedFolder = Bundle.module.resourceURL!.appendingPathComponent("ShepherdSeeds")
        #endif
        let names = ["push-settings", "push-envelope", "push-receipt", "push-ledger"]
        let seeds = try names.map { try Data(contentsOf: seedFolder.appendingPathComponent($0 + ".json")) }
        for (a,b) in zip(seeds,generated) {
            try require(try NSDictionary(dictionary: JSONSerialization.jsonObject(with:a) as! [String:Any]).isEqual(to: JSONSerialization.jsonObject(with:b) as! [String:Any]), "SH38 committed seeds match exact current encoder contract")
        }
        func accept(_ data: Data, _ kind: Int) throws -> Bool {
            do {
                switch kind {
                case 0:
                    let v = try RelayShepherdPushSettings.decode(data); let round = try RelayShepherdPushSettings.decode(encoder.encode(v))
                    try require(v == round, "SH38 target settings exact ID roundtrip")
                case 1:
                    let v = try RelayShepherdPushEnvelope.decode(data); let round = try RelayShepherdPushEnvelope.decode(encoder.encode(v))
                    try require(v == round && v.packet["pane_id"] as? String == v.target.paneID, "SH38 envelope preserves exact target")
                case 2:
                    let v = try RelayShepherdPushReceipt.decode(data, envelope: envelope)
                    try require(v.targetID == envelope.target.paneID && v.messageID == envelope.messageID, "SH38 receipt preserves exact IDs")
                default:
                    let v = try RelayShepherdPushLedger.decode(data)
                    try require(v.entries.count <= RelayShepherdPushLedger.entryLimit, "SH38 bounded retained ledger")
                    let round = try RelayShepherdPushLedger.decode(encoder.encode(v))
                    try require(v.entries.map(\.messageID) == round.entries.map(\.messageID) && v.entries.map(\.targetID) == round.entries.map(\.targetID), "SH38 ledger IDs roundtrip exactly")
                }
                return true
            } catch is RelayShepherdChecks.Failure { throw RelayShepherdChecks.Failure(description: "SH38 roundtrip property") }
            catch { return false }
        }
        let priorLedger = try Data(contentsOf: seedFolder.appendingPathComponent("push-ledger-prior.json"))
        try require(try !accept(priorLedger,3), "SH51 historical ledger missing occurrence state fails closed")
        for (kind, seed) in seeds.enumerated() {
            try require(try accept(seed,kind), "SH38 committed valid seed")
            for n in 0..<seed.count { try require(try !accept(seed.prefix(n),kind), "SH38 reject every truncated seed prefix") }
            var object = try JSONSerialization.jsonObject(with: seed) as! [String:Any];object["unexpected"] = 1
            try require(try !accept(JSONSerialization.data(withJSONObject: object),kind), "SH38 reject unknown root keys")
        }
        // Check nested settings/recipient keys, exact destination identity and
        // forbidden source claims independently of the random mutation stream.
        for kind in 0...1 {
            let original = try JSONSerialization.jsonObject(with: seeds[kind]) as! [String:Any]
            var obj = original
            var targetObject = obj["target"] as! [String:Any]; targetObject["unexpected"] = true; obj["target"] = targetObject
            try require(try !accept(JSONSerialization.data(withJSONObject: obj),kind), "SH38 unknown target keys")
            obj = original; targetObject = obj["target"] as! [String:Any]
            var recipient = targetObject["recipient"] as! [String:Any];recipient["unexpected"] = 1
            targetObject["recipient"] = recipient;obj["target"] = targetObject
            try require(try !accept(JSONSerialization.data(withJSONObject: obj),kind), "SH38 unknown recipient keys")
        }
        var ledgerObject = try JSONSerialization.jsonObject(with: seeds[3]) as! [String:Any]
        var entries = ledgerObject["entries"] as! [[String:Any]];entries[0]["unexpected"] = 1;ledgerObject["entries"] = entries
        try require(try !accept(JSONSerialization.data(withJSONObject: ledgerObject),3), "SH38 unknown persisted entry keys")
        ledgerObject = try JSONSerialization.jsonObject(with: seeds[3]) as! [String:Any];ledgerObject["uiReports"] = Int.max
        try require(try !accept(JSONSerialization.data(withJSONObject: ledgerObject),3), "SH47 malicious counter cannot overflow on observation")
        var receiptObj = try JSONSerialization.jsonObject(with: seeds[2]) as! [String:Any];receiptObj["pane_id"] = target(1).paneID
        try require(try !accept(JSONSerialization.data(withJSONObject: receiptObj),2), "SH38 changed receipt target rejected")
        receiptObj = try JSONSerialization.jsonObject(with: seeds[2]) as! [String:Any];receiptObj["source_authentication"] = "kernel_verified"
        try require(try !accept(JSONSerialization.data(withJSONObject: receiptObj),2), "SH36 false attestation rejected")
        receiptObj = try JSONSerialization.jsonObject(with: seeds[2]) as! [String:Any];receiptObj["replay_permitted"] = 0
        try require(try !accept(JSONSerialization.data(withJSONObject: receiptObj),2), "SH43 numeric false is not a Boolean receipt")
        receiptObj = try JSONSerialization.jsonObject(with: seeds[2]) as! [String:Any];receiptObj["replay_permitted"] = true
        try require(try !accept(JSONSerialization.data(withJSONObject: receiptObj),2), "SH49 replay-permitted receipt rejected")
        var random: UInt64 = 0x53483250555348
        func next() -> UInt64 { random ^= random << 13; random ^= random >> 7; random ^= random << 17; return random }
        let started = Date(); var last = started
        for i in 1...iterations {
            let kind = Int(next() % 4); var data = seeds[kind]
            switch next() % 4 {
            case 0: data = data.prefix(Int(next() % UInt64(data.count + 1)))
            case 1: let at = Int(next() % UInt64(data.count)); data[at] = UInt8(truncatingIfNeeded: next())
            case 2: data.append(contentsOf: [UInt8(truncatingIfNeeded: next()),0])
            default: data = Data((0..<Int(next()%512)).map { _ in UInt8(truncatingIfNeeded: next()) })
            }
            _ = try accept(data,kind)
            if i % 5000 == 0 { let now=Date(); print("SH2-FUZZ execs=\(i) elapsed=\(now.timeIntervalSince(started)) batch_execs_per_sec=\(5000 / max(now.timeIntervalSince(last),0.000001))");last=now }
        }
    }
}
