import Foundation
import Testing
@testable import Relay

/// RelayAgentSignIn.redact runs on terminal and agent text, so its patterns
/// must stay linear on long runs (hashes, base64) and the anchored fragment
/// pattern must redact exactly what the original pattern did.
struct RelayRedactionComplexityTests {
    static let original = #"[A-Za-z0-9_-]{8,}#[A-Za-z0-9_-]+"#

    @Test("The anchored fragment pattern redacts exactly what the original did")
    func anchoredMatchesOriginal() {
        let alphabet: [String] = ["a", "B", "7", "_", "-", "#", " ", "?", "&", "=", "code=", "é", "\n"]
        for seed in [UInt64(1), 0x5eed_0029_1029, 0xdead_beef] {
            var rng = SplitMix64(state: seed)
            for _ in 0..<3000 {
                var text = ""
                for _ in 0..<rng.below(40) { text += alphabet[rng.below(alphabet.count)] }
                // The other two patterns run first in both, so compare after them.
                var expected = text
                for pattern in [#"(?<![A-Z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4,5}(?![A-Z0-9-])"#, #"(?<=[?&#](code|state)=)[^&#\s]+"#, Self.original] {
                    expected = expected.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
                }
                #expect(RelayAgentSignIn.redact(text) == expected, "seed \(seed): \(text.debugDescription)")
            }
        }
    }

    @Test("Redaction stays linear on a long run without a fragment marker")
    func longRunsAreLinear() {
        let run = String(repeating: "x", count: 64 << 10) + " end"
        let started = Date()
        #expect(RelayAgentSignIn.redact(run) == run)
        #expect(RelayAgentSignIn.redact(String(repeating: "x", count: 64 << 10) + "#frag") == "[redacted]")
        // Every character of the run class, so no start inside a run is cheap to skip.
        let mixed = String(repeating: "a_-9", count: 16 << 10) + " end"
        #expect(RelayAgentSignIn.redact(mixed) == mixed)
        // The quadratic pattern takes minutes here; the bound is generous for debug builds.
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
