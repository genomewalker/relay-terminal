import Foundation
import Testing
@testable import Relay

// Seeded fuzz targets for Miko's screen and exact-record readers: the
// viewport tail bound (terminal text from any process) and the chitta
// exact-record parsers (output of another process). Seeds are fixed so every
// run replays the same inputs; add found crashers to `regressions`.

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

@Suite("RelayAssistantReadFuzz")
struct RelayAssistantReadFuzzTests {
    static let seeds: [UInt64] = [1, 0x5eed_0029_1029, 0xdead_beef, 0x6746_1977_2273_2167]
    static let regressions = [
        "", "\n", "\u{1b}[2J\u{1b}[H", String(repeating: "🇩🇰", count: 3000), String(repeating: "e\u{301}\u{302}\u{303}", count: 2000),
        "xtoken=abcdefghijklmnop " + String(repeating: "y", count: 5000),
        String(repeating: "a", count: 4100) + "\nsk-ant-" + String(repeating: "Q", count: 30),
        // Found while writing this target: the 8 KB diagnostic cap dropped the bottom of long screens.
        (0..<400).map { "line \($0) " + String(repeating: "x", count: 30) }.joined(separator: "\n") + "\n> latest reply",
        String(repeating: "z ", count: 3500) + "-----BEGIN RSA PRIVATE KEY-----\nMIIEsecretbody\n",
        "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "MIIEsecretbody\n", count: 600) + "-----END RSA PRIVATE KEY-----\n$ ok",
        String(repeating: "q", count: 9000) + "token=abcdefghijkl" + String(repeating: "r", count: 9000),
    ]
    static let pieces = ["ls -la", "\n", "\t", "\r", "\u{1b}[31m", "\u{0}", "\u{7f}", "é", "日本語", "🇩🇰", "e\u{301}",
                         "> reply", String(repeating: "-", count: 120), "$ ", "\u{2028}"]
    static let secrets = ["sk-ant-abcdefghijklmnopqrstuv", "token=abcdefghijkl", "ghp_abcdefghijklmnopqrstuvwxyz",
                          "AKIAABCDEFGHIJKLMNOP", "password: hunter2hunter2", "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.c2lnbmF0dXJlMTIz",
                          "-----BEGIN RSA PRIVATE KEY-----\nMIIEsecretbody\nMIIEsecretbody\n-----END RSA PRIVATE KEY-----"]
    /// Text that must never appear in output; a secret's own distinctive part.
    static let forbidden = ["abcdefghijklmnopqrstuv", "abcdefghijkl", "hunter2hunter2", "ABCDEFGHIJKLMNOP", "MIIEsecretbody", "c2lnbmF0dXJlMTIz", "QQQQQQQQQQQQ"]

    static func text(_ rng: inout SplitMix64, secrets withSecrets: Bool) -> String {
        var out = ""
        for _ in 0..<rng.below(900) {
            if withSecrets, rng.below(40) == 0 { out += " " + secrets[rng.below(secrets.count)] + " " }
            else { out += pieces[rng.below(pieces.count)] }
        }
        return out
    }

    private static func controlFree(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
    }

    @Test("Viewport tail: bounded bytes, no control characters, no surviving secret, a true suffix when nothing is redacted")
    func viewportTail() {
        var cases = 0
        for seed in Self.seeds {
            var rng = SplitMix64(state: seed)
            for round in 0..<600 {
                let withSecrets = round % 2 == 0
                let input = round < Self.regressions.count ? Self.regressions[round] : Self.text(&rng, secrets: withSecrets)
                let limit = [64, 300, 1000, RelayAssistantHarness.viewportLimit][rng.below(4)]
                let output = RelayAssistantRedaction.boundedTail(input, limit: limit)
                // Oracle for inputs without secrets: the input with control characters removed.
                let whole = String(String.UnicodeScalarView(input.unicodeScalars.filter {
                    $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }))
                let hasSecret = Self.secrets.contains { input.contains($0) } || Self.forbidden.contains { input.contains($0) }
                cases += 1
                #expect(output.utf8.count <= limit, "seed \(seed) round \(round)")
                #expect(Self.controlFree(output), "seed \(seed) round \(round)")
                #expect(RelayAssistantRedaction.redact(output) == output, "seed \(seed) round \(round)")
                for secret in Self.forbidden { #expect(!output.contains(secret), "seed \(seed) round \(round)") }
                // Redaction may shorten text below the limit, so marker and suffix
                // properties are exact only for inputs without secrets.
                guard !hasSecret else { continue }
                if whole.utf8.count > limit { #expect(output.hasPrefix("[earlier lines truncated] …\n"), "seed \(seed) round \(round)") }
                if whole.utf8.count <= limit {
                    #expect(output == whole, "seed \(seed) round \(round)")
                } else {
                    let body = output.dropFirst("[earlier lines truncated] …\n".count)
                    #expect(whole.hasSuffix(body), "seed \(seed) round \(round)")
                    // It starts on a line (or word) boundary of the input, never mid-word.
                    let before = whole.dropLast(body.count)
                    #expect(body.isEmpty || before.last.map { $0 == "\n" || $0.isWhitespace } == true, "seed \(seed) round \(round)")
                    // The bottom line survives whenever it fits.
                    if let last = whole.split(separator: "\n", omittingEmptySubsequences: false).last, last.utf8.count < limit / 2 {
                        #expect(body.hasSuffix(last), "seed \(seed) round \(round)")
                    }
                }
            }
        }
        #expect(cases == Self.seeds.count * 600)
    }

    @Test("Exact-record parsers: truncated or altered output is rejected; only the requested record is returned")
    func exactRecordParsers() {
        typealias Store = RelayChittaMemoryStore
        let node = Data(#"{"id":"6746197722732167252","content":"HANDOFF ok","type":"episode","realm":"project:term"}"#.utf8)
        let checkpoint = Data(#"{"key":"s:p","snapshot":"Task","snapshot_truncated":false,"next_steps":["a"],"blockers":[],"project":"p"}"#.utf8)
        // Every strict prefix is truncated output and must be refused.
        for n in 0..<node.count { #expect(throws: RelayAssistantMemoryError.self) { try Store.exactNode(node.prefix(n), id: "6746197722732167252") } }
        for n in 0..<checkpoint.count { #expect(throws: RelayAssistantMemoryError.self) { try Store.exactCheckpoint(checkpoint.prefix(n), key: "s:p") } }
        var cases = 0
        for seed in Self.seeds {
            var rng = SplitMix64(state: seed)
            for _ in 0..<1500 {
                var bytes = [UInt8](rng.below(2) == 0 ? node : checkpoint)
                for _ in 0...rng.below(4) {
                    switch rng.below(3) {
                    case 0: bytes[rng.below(bytes.count)] = UInt8(truncatingIfNeeded: rng.next())
                    case 1: bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: rng.below(bytes.count + 1))
                    default: if bytes.count > 1 { bytes.remove(at: rng.below(bytes.count)) }
                    }
                }
                let data = Data(bytes)
                let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                cases += 1
                let row = parsed as? [String: Any]
                if case .success(let result) = Result(catching: { try Store.exactNode(data, id: "6746197722732167252") }) {
                    if let item = result {
                        // Only a string id equal to the request: never a bridged number or boolean.
                        #expect(row?["id"] is String && row?["id"] as? String == "6746197722732167252" && row?["content"] as? String == item.text)
                    } else {
                        #expect(parsed is NSNull)
                    }
                }
                if case .success(let result) = Result(catching: { try Store.exactCheckpoint(data, key: "s:p") }) {
                    if let item = result {
                        #expect(row?["key"] as? String == "s:p" && item.kind == "checkpoint")
                        // The flag is a real JSON boolean and is carried through unchanged.
                        let flag = row?["snapshot_truncated"] as? NSNumber
                        #expect(flag.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue == item.truncated } == true)
                        #expect(item.text.hasPrefix(row?["snapshot"] as? String ?? "\u{0}"))
                    } else {
                        #expect(parsed is NSNull)
                    }
                }
            }
        }
        #expect(cases == Self.seeds.count * 1500)
    }

    // Root review of r2 (SOURCE-REVIEW-r2-15dc66be.md): RelayDiagnostics.redact cut at 8192 characters before
    // the assistant patterns, so a handoff lost its tail while reporting complete.
    @Test("Handoff completeness comes from every cap: a lost tail is never reported complete")
    func handoffCompletenessRegressions() {
        let requested: [String: RelayPaneHealthJSON] = ["memory_id": .string("1")]
        let final = "HANDOFF final job status must survive"
        let secretLong = RelayAssistantHarness.handoffResult(
            .init(text: "token=" + String(repeating: "a", count: 9000) + "\n" + final, kind: "episode", realm: "t"), requested: requested)
        #expect(secretLong["text"]?.string?.hasSuffix(final) == true && secretLong["complete"]?.boolean == true)
        let plainLong = RelayAssistantHarness.handoffResult(
            .init(text: String(repeating: "b", count: 9000) + "\n" + final, kind: "episode", realm: "t"), requested: requested)
        #expect(plainLong["complete"]?.boolean == false && plainLong["warning"] != nil)
        let quotes = RelayAssistantHarness.handoffResult(
            .init(text: String(repeating: "\"", count: 3990), kind: "episode", realm: "t"), requested: requested)
        #expect(RelayAssistantHarness.encodedSize(quotes) <= RelayAssistantHarness.resultLimit)
        #expect(quotes["complete"]?.boolean == false)
        #expect(RelayAssistantRedaction.redact(String(repeating: "c", count: 9000) + final).hasSuffix(final))
        // A secret straddling the redaction window is dropped, never left partly visible.
        for secret in ["token=abcdefghijklmnop", "sk-ant-" + String(repeating: "Q", count: 30)] {
            for shift in [3, 5, 9, 14] {
                let text = String(repeating: "x", count: (16 << 10) - shift) + " " + secret + "\n" + final
                let (head, cut) = RelayAssistantRedaction.headWindow(text, bytes: 16 << 10)
                #expect(cut && !head.contains(secret.prefix(shift - 1)) && head.utf8.count <= 16 << 10)
                let shown = RelayAssistantHarness.handoffResult(.init(text: text, kind: "episode", realm: "t"), requested: requested)
                #expect(shown["complete"]?.boolean == false && shown["text"]?.string?.contains(secret.prefix(shift - 1)) == false)
            }
        }
        // A record with no line or word start in its window shows nothing, and is never complete.
        let unbroken = RelayAssistantHarness.handoffResult(.init(text: String(repeating: "z", count: 20_000), kind: "episode", realm: "t"), requested: requested)
        #expect(unbroken["complete"]?.boolean == false && unbroken["warning"] != nil)
        let keyed = String(repeating: "y ", count: 8000) + "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "MIIEsecretbody\n", count: 200)
        #expect(!RelayAssistantRedaction.headWindow(keyed, bytes: 16 << 10).text.contains("MIIEsecretbody"))
        // The largest record chitta can return still fits, and is reported incomplete.
        let largest = String(repeating: "🇩🇰 token=abcdefghijkl\n", count: RelayChittaMemoryStore.outputLimit / 28)
        #expect(largest.utf8.count <= RelayChittaMemoryStore.outputLimit && largest.utf8.count > RelayChittaMemoryStore.outputLimit - 64)
        let capped = RelayAssistantHarness.handoffResult(.init(text: largest, kind: "episode", realm: "t"), requested: requested)
        #expect(RelayAssistantHarness.encodedSize(capped) <= RelayAssistantHarness.resultLimit && capped["complete"]?.boolean == false)
    }

    @Test("Handoff fuzz: complete means the whole redacted record is present, and the result always fits")
    func handoffCompletenessFuzz() {
        let pieces = Self.pieces + ["\"", "\\", "token=abcdefghijkl ", String(repeating: "w", count: 700), "\n"]
        var cases = 0, completes = 0, incompletes = 0
        for seed in Self.seeds {
            var rng = SplitMix64(state: seed)
            for _ in 0..<300 {
                var text = ""
                for _ in 0..<rng.below(rng.below(2) == 0 ? 60 : 900) {
                    // A record never exceeds the bytes Relay reads from chitta.
                    let piece = pieces[rng.below(pieces.count)]
                    guard text.utf8.count + piece.utf8.count <= RelayChittaMemoryStore.outputLimit else { break }
                    text += piece
                }
                let item = RelayAssistantMemoryItem(text: text, kind: "episode", realm: "t", truncated: rng.below(5) == 0)
                let result = RelayAssistantHarness.handoffResult(item, requested: ["memory_id": .string("1")])
                cases += 1
                #expect(RelayAssistantHarness.encodedSize(result) <= RelayAssistantHarness.resultLimit, "seed \(seed)")
                if result["complete"]?.boolean == true {
                    completes += 1
                    // Only a small record can be complete, so the whole-text oracle stays cheap.
                    let whole = RelayAssistantRedaction.boundedFlagged(text, limit: .max).text
                    #expect(!item.truncated && result["text"]?.string == whole && result["warning"] == nil, "seed \(seed)")
                } else {
                    incompletes += 1
                    #expect(result["complete"]?.boolean == false && result["warning"] != nil, "seed \(seed)")
                }
            }
        }
        #expect(cases == Self.seeds.count * 300 && completes > 0 && incompletes > 0)
    }
}
