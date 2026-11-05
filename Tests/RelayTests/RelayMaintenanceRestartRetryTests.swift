import Foundation
import Testing
@testable import Relay

/// Exhaustive bounded check of the maintenance-exit retry: every script of
/// attempt outcomes and pane-still-current answers up to the retry limit,
/// against an independent oracle.
@MainActor @Suite("Maintenance restart retry bounded check")
struct RelayMaintenanceRestartRetryTests {
    typealias Outcome = TerminalRuntime.AgentMaintenanceSendOutcome

    struct Expected: Equatable {
        let result: Outcome
        let held: Bool
        let attempts: Int
        let sleeps: Int
    }

    /// A probe per readmission, told apart by its process ID, so the check can
    /// see which evidence each attempt was sent against.
    static func probe(_ process: Int) throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"p","provider":"claude","process_id":\#(process),"process_start":99,"session_id":"s","lifecycle":"quiet"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }

    /// The oracle: attempt; while it reports an open phase and retries remain,
    /// sleep, then readmit; a hold stops (phase open, held), else attempt again.
    static func oracle(_ outcomes: [Outcome], _ admit: [Bool], limit: Int) -> Expected {
        var attempts = 1, sleeps = 0
        var result = outcomes[0]
        while result == .outputPhaseOpen, sleeps < limit {
            sleeps += 1
            if !admit[sleeps - 1] { return Expected(result: .outputPhaseOpen, held: true, attempts: attempts, sleeps: sleeps) }
            result = outcomes[attempts]
            attempts += 1
        }
        return Expected(result: result, held: false, attempts: attempts, sleeps: sleeps)
    }

    @Test("Exhaustive bounded check: retries only an open phase, at most `limit` times, readmitting after each sleep and sending against the readmitted evidence")
    func boundedRetryCheck() async throws {
        let all: [Outcome] = [.sent, .outputPhaseOpen, .refused]
        let initial = try Self.probe(1000)
        let refreshed = try (0..<4).map { try Self.probe(2000 + $0) }
        var scripts = 0
        for limit in 0...3 {
            let outcomeScripts = Int(pow(3.0, Double(limit + 1)))
            let admitScripts = 1 << limit
            for o in 0..<outcomeScripts {
                var outcomes: [Outcome] = [], rest = o
                for _ in 0...limit { outcomes.append(all[rest % 3]); rest /= 3 }
                for c in 0..<admitScripts {
                    let admit = (0..<limit).map { c & (1 << $0) != 0 }
                    var attempts = 0, sleeps = 0, readmissions = 0
                    var sentAgainst: [Int?] = []
                    let result = try await RelayAgentMaintenanceRestartAdmission.send(
                        initial: initial,
                        attempt: { proof in
                            defer { attempts += 1 }
                            sentAgainst.append(proof.processID)
                            return attempts < outcomes.count ? outcomes[attempts] : .sent
                        },
                        readmit: {
                            defer { readmissions += 1 }
                            #expect(readmissions == sleeps - 1, "one readmission after each sleep, never before it")
                            return admit[readmissions] ? .admit(refreshed[readmissions]) : .hold("changed")
                        },
                        sleep: { sleeps += 1 },
                        limit: limit)
                    let expected = Self.oracle(outcomes, admit, limit: limit)
                    #expect(Expected(result: result.outcome, held: result.held != nil, attempts: attempts, sleeps: sleeps) == expected,
                            "limit \(limit), outcomes \(outcomes), admit \(admit)")
                    #expect(attempts <= limit + 1)
                    #expect(readmissions == sleeps, "every sleep is followed by a readmission")
                    // The first attempt uses the original evidence; every retry
                    // uses the evidence its own readmission just produced.
                    #expect(sentAgainst == [1000] + (0..<max(0, attempts - 1)).map { 2000 + $0 },
                            "limit \(limit), outcomes \(outcomes), admit \(admit)")
                    if result.outcome == .refused || result.outcome == .sent {
                        #expect(outcomes[attempts - 1] == result.outcome, "stops at the first non-phase outcome")
                        #expect(result.held == nil)
                    }
                    scripts += 1
                }
            }
        }
        // Σ over limit 0...3 of 3^(limit+1) · 2^limit = 3 + 18 + 108 + 648.
        #expect(scripts == 777)
    }

    @Test("The production bound is about 30 s, the reconnect replay's failsafe: 60 retries, 500 ms apart")
    func productionBound() {
        #expect(RelayAgentMaintenanceRestartAdmission.retryLimit == 60)
        #expect(RelayAgentMaintenanceRestartAdmission.retryInterval == .milliseconds(500))
    }
}
