import XCTest
@testable import Relay

final class RelayClaudeQuotaRandomizedTests: XCTestCase {
    struct Random {
        var state: UInt64 = 0x1631_a561_ece8_2026
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        mutating func mutate(_ seed: Data) -> Data {
            var bytes = [UInt8](seed)
            switch next() % 5 {
            case 0: bytes = Array(bytes.prefix(Int(next() % UInt64(max(1, bytes.count)))))
            case 1: if !bytes.isEmpty { bytes[Int(next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: next() >> 32) }
            case 2: bytes.append(UInt8(truncatingIfNeeded: next() >> 32))
            case 3: bytes = (0..<(next() % 512)).map { _ in UInt8(truncatingIfNeeded: next() >> 32) }
            default: break
            }
            return Data(bytes)
        }
    }
    func testRandomizedStrictSettingsAndJournal() throws {
        let fixtures = RelayClaudeQuotaFailoverTests()
        var seedDisk = try fixtures.away().disk
        seedDisk.records[0].operation = UUID(uuidString: "00000000-0000-4000-8000-000000001631")!
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let settingsSeed = try encoder.encode(RelayClaudeQuotaSettings())
        let recordSeed = try encoder.encode(seedDisk)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: recordSeed) as? [String: Any])
        var legacyRows = try XCTUnwrap(legacy["records"] as? [[String: Any]])
        legacyRows[0].removeValue(forKey: "triggerResets"); legacy["records"] = legacyRows; legacy["version"] = 1
        let legacySeed = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        let seeds: [(Data, Bool)] = [(settingsSeed, false), (recordSeed, true), (legacySeed, true)]
        var random = Random()
        let started = Date()
        var accepted = 0
        for i in 0..<10_000 {
            for (seed, record) in seeds {
                let data = random.mutate(seed)
                if record {
                    if let value = try? RelayClaudeQuotaEngine.Disk.decode(data) {
                        accepted += 1
                        XCTAssertEqual(try RelayClaudeQuotaEngine.Disk.decode(JSONEncoder().encode(value)), value, "exact record round trip")
                    }
                } else if let value = try? RelayClaudeQuotaSettings.decode(data) {
                    accepted += 1
                    XCTAssertTrue(value.valid)
                    XCTAssertEqual(RelayClaudeQuotaSettings.restored(data), value)
                    XCTAssertEqual(try RelayClaudeQuotaSettings.decode(JSONEncoder().encode(value)), value)
                } else {
                    XCTAssertFalse(RelayClaudeQuotaSettings.restored(data).enabled, "invalid saved settings must disable failover")
                }
            }
            if (i + 1) % 2000 == 0 {
                let elapsed = Date().timeIntervalSince(started)
                print("QF randomized: seed=0x1631a561ece82026; execs=\((i+1)*3); elapsed=\(elapsed); execs/sec=\(Double((i+1)*3)/elapsed)")
            }
        }
        XCTAssertGreaterThan(accepted, 0)
        for (seed, isRecord) in seeds {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: seed) as? [String: Any])
            object["unknown"] = true
            let data = try JSONSerialization.data(withJSONObject: object)
            if isRecord { XCTAssertThrowsError(try RelayClaudeQuotaEngine.Disk.decode(data)) }
            else { XCTAssertThrowsError(try RelayClaudeQuotaSettings.decode(data)) }
            // All byte truncations of a known-valid seed are rejected.
            for length in 0..<seed.count {
                if isRecord { XCTAssertThrowsError(try RelayClaudeQuotaEngine.Disk.decode(seed.prefix(length))) }
                else { XCTAssertThrowsError(try RelayClaudeQuotaSettings.decode(seed.prefix(length))) }
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: recordSeed) as? [String: Any])
        var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        rows[0]["unknown"] = true; object["records"] = rows
        XCTAssertThrowsError(try RelayClaudeQuotaEngine.Disk.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try RelayClaudeQuotaSettings.decode(Data(repeating: 32, count: (64 << 10) + 1)))
        XCTAssertThrowsError(try RelayClaudeQuotaEngine.Disk.decode(Data(repeating: 32, count: (1 << 20) + 1)))
    }

    @MainActor func testNormalizedQuotaAdmissionRejectsInvalidOrStaleWindows() throws {
        let now = Date(timeIntervalSince1970: 1792770000)
        for percent in [-1.0, 0, 89, 90, 95, 100, 101, 1000] {
            for reset in ["2026-10-23T17:00:00Z", "2026-10-23T19:00:00.123456+02:00", "invalid", "2020-01-01T00:00:00Z"] {
                for age in [-1.0, 0, 120, 121] {
                    let formatter = ISO8601DateFormatter()
                    let usage = RelayAgentAccountUsage(provider: "claude", label: "business", status: "ok", reason: nil,
                        source: "claude get_usage", readAt: formatter.string(from: now.addingTimeInterval(-age)),
                        windows: [.init(name: "five_hour", usedPercent: percent, resetsAt: reset, windowMinutes: 300),
                                  .init(name: "seven_day", usedPercent: percent, resetsAt: reset, windowMinutes: 10080)])
                    let value = RelayClaudeQuotaScheduler.quota(usage, now: now)
                    let expected = (0...100).contains(percent) && (0...120).contains(age) && reset.hasPrefix("2026")
                    XCTAssertEqual(value != nil, expected)
                    if let value { XCTAssertTrue(value.current(now)) }
                }
            }
        }
    }
}
