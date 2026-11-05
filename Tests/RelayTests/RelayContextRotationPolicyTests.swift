import Foundation
import Testing
@testable import Relay

@Suite struct RelayContextRotationPolicyTests {
    static let status = Data(#"{"v":1,"session_id":"fixture","turn_seq":12,"owner":"relay","signal":null,"claim":null,"intent":null,"ack":null,"usage":{"session":{"input":100,"cached_input":90,"uncached_input":10,"output":10,"responses":8,"turns":4},"context_tokens":300000,"client":{"value":"codex","provenance":"hook"},"in_flight_tool":{"value":false,"provenance":"transcript"},"turn_id_fresh":{"value":true,"provenance":"transcript"},"transcript_mtime_ms_at_stop":{"value":99000,"provenance":"hook"}}}"#.utf8)

    @Test func packagedReviewedPolicyMakesNoDollarClaim() async throws {
        let policy = RelayNativeContextRotationPolicy()
        let status = Self.status
        let output = try await policy.evaluate(status: status, now: Date(timeIntervalSince1970: 100))
        let result = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(result["decision"] as? String == "rotate")
        let economics = try #require(result["economics"] as? [String: Any])
        #expect(economics["cache_cold"] is NSNull, "Codex must not inherit an assumed Claude cache TTL")
        #expect(result["total_cost_usd"] == nil)
        let signal = try #require(result["signal"] as? [String: Any])
        #expect(signal["session_id"] as? String == "fixture")
        #expect(signal["epoch"] as? String == "turn-12")
    }

    struct Golden: Decodable {
        struct Case: Decodable {
            let name: String
            let now_ms: Int64
            let input: String
            let exit_code: Int
            let stdout: String?
        }
        let cases: [Case]
    }

    /// The goldens are stdout of the original Python policy for the same stdin
    /// and --now-ms; relayd's Go port is pinned to the same file.
    static func golden() throws -> Golden {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("remote/relayd/internal/daemon/testdata/host_rotation_policy/golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: file))
    }

    @Test func matchesEveryPythonGoldenByte() throws {
        let golden = try Self.golden()
        #expect(golden.cases.count >= 100)
        var failed = 0
        for item in golden.cases {
            let output = try? RelayRotationPolicyRules.evaluate(status: Data(item.input.utf8), nowMS: item.now_ms)
            if item.exit_code != 0 {
                if output != nil { failed += 1 }
                #expect(output == nil, "\(item.name): Python exited \(item.exit_code)")
                continue
            }
            let text = output.map { String(decoding: $0, as: UTF8.self) }
            if text != item.stdout { failed += 1 }
            #expect(text == item.stdout, "\(item.name)")
        }
        #expect(failed == 0)
    }

    /// Boundaries the goldens do not reach, computed by hand from policy.py.
    @Test func economicsAndScheduleBoundaries() throws {
        typealias JSON = RelayPythonJSON
        // codex: 2 calls/turn x (128000 - 38000) x 0.25 x 2 turns == 38000 x 1.0 + 52000, so net == 0 holds.
        let status = String(decoding: Self.status, as: UTF8.self)
        func decision(context: Int) throws -> String {
            let output = try RelayRotationPolicyRules.evaluate(status: Data(status.replacingOccurrences(
                of: #""context_tokens":300000"#, with: #""context_tokens":\#(context)"#).utf8), nowMS: 100_000)
            return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])["decision"] as? String ?? ""
        }
        #expect(try decision(context: 128_000) == "hold")
        #expect(try decision(context: 128_001) == "rotate")
        // reserve = max(1, min(30000, ttl // 10)); prepare = request + ttl - reserve.
        guard case .dict(let document) = try JSON.decode(Data(#"{"session_id":"s","turn_seq":1,"usage":{"model":"m","last_model_request_ms":{"value":1000,"provenance":"transcript"},"last_model_response_ms":{"value":2000,"provenance":"transcript"},"cache_ttl_ms":{"value":60000,"provenance":"hook"}}}"#.utf8)),
              case .dict(let usage)? = document["usage"] else { Issue.record("fixture"); return }
        let schedule = try RelayRotationPolicyRules.cacheSchedule(document, usage, nowMS: 3_000)
        #expect((schedule["preparation_reserve_ms"] ?? .none).equals(.int(6_000)))
        #expect((schedule["next_evaluation_ms"] ?? .none).equals(.int(55_000)))
        #expect((schedule["state"] ?? .none).equals(.text("before_expiry")))
    }

    @Test func pythonValueModelEdges() throws {
        typealias JSON = RelayPythonJSON
        func roundTrip(_ text: String) throws -> String { JSON.dumps(try JSON.decode(Data(text.utf8))) }
        #expect(try roundTrip(#"{"b": 1, "a": [1.0, 1e16, 1e-05, 0.0001, -0.0, 1e400, NaN, -Infinity, 123456789012345678901234567890]}"#)
            == #"{"b": 1, "a": [1.0, 1e+16, 1e-05, 0.0001, -0.0, Infinity, NaN, -Infinity, 123456789012345678901234567890]}"#)
        #expect(try roundTrip(#"{"a": 1, "b": 2, "a": 3}"#) == #"{"a": 3, "b": 2}"#)
        #expect(try roundTrip(#""\ud83d\ude00\ud800x\u00e9\u007f""#) == #""\ud83d\ude00\ud800x\u00e9\u007f""#)
        #expect(try roundTrip("\"\u{1F600}\"") == #""\ud83d\ude00""#)
        for invalid in ["{\"a\": 1,}", "[1,]", "01", "1.", "\u{FEFF}{}", "{\"a\"\n:\t\"\u{1}\"}", "\"\\x\"", "nul", "{} x",
                        "\"\\ud800\\uzzzz\"", String(repeating: "9", count: 4301)] {
            #expect((try? JSON.decode(Data(invalid.utf8))) == nil, "\(invalid.prefix(20))")
        }
        // Nesting is bounded, and the policy keeps its recursion off this thread.
        let deep = String(repeating: "[", count: 899) + String(repeating: "]", count: 899)
        let status = String(decoding: Self.status, as: UTF8.self)
        let nested = Data(status.replacingOccurrences(of: #""owner":"relay""#, with: #""owner":"relay","deep":"# + deep).utf8)
        #expect(try RelayRotationPolicyRules.evaluate(status: nested, nowMS: 100_000)
                == RelayRotationPolicyRules.evaluate(status: Self.status, nowMS: 100_000))
        let tooDeep = Data(status.replacingOccurrences(of: #""owner":"relay""#, with: #""owner":"relay","deep":["# + deep + "]").utf8)
        #expect((try? RelayRotationPolicyRules.evaluate(status: tooDeep, nowMS: 100_000)) == nil)
        #expect((try? JSON.decode(Data([0x22, 0xED, 0xA0, 0x80, 0x22]))) == nil, "UTF-8 surrogate")
        #expect((try? JSON.decode(Data([0x22, 0xC0, 0x80, 0x22]))) == nil, "overlong")
        #expect(try roundTrip(String(repeating: "9", count: 4300)) == String(repeating: "9", count: 4300))
        #expect(JSON.floatRepr(0.1) == "0.1" && JSON.floatRepr(1e22) == "1e+22" && JSON.floatRepr(123.0) == "123.0")
        #expect(JSON.floatRepr(1234567890123456.8) == "1234567890123456.8" && JSON.floatRepr(5e-324) == "5e-324")
        #expect(JSON.dumps(try JSON.round(2.5)) == "2")
        #expect(JSON.dumps(try JSON.round(3.5)) == "4")
        #expect(JSON.dumps(try JSON.round(1e20)) == "100000000000000000000")
        #expect(JSON.dumps(try JSON.round(-9.3e18)) == "-9300000000000000000")
        // Python rounds the binary value: 2.0005 is above the tie, 2.675 below it.
        #expect(JSON.round(2.0005, digits: 3) == 2.001 && JSON.round(2.675, digits: 2) == 2.67)
        #expect(JSON.round(0.6666666, digits: 3) == 0.667 && JSON.round(0.5, digits: 0) == 0.0)
        #expect(JSON.repr(.text("it's")) == #""it's""# && JSON.repr(.text("a'\"\n\u{7}")) == #"'a\'"\n\x07'"#)
        #expect(JSON.repr(.string(JSON.Text(codePoints: [0xE9, 0xD800, 0x200B, 0x1F600]))) == "'\u{E9}\\ud800\\u200b\u{1F600}'")
        #expect(JSON.repr(.bool(true)) == "True" && JSON.repr(.none) == "None" && JSON.repr(.float(2)) == "2.0")
        #expect(JSON.Value.float(1).equals(.int(1)) && JSON.Value.bool(true).equals(.int(1)))
        #expect(!JSON.Value.float(1.5).equals(.int(1)) && !JSON.Value.text("1").equals(.int(1)))
        #expect(JSON.Value.float(1e20).equals(.bigInt("100000000000000000000")))
    }
}
