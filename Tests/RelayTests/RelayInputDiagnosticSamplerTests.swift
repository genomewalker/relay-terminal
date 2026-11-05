import Foundation
import Testing
@testable import Relay

@Suite("Continuous bounded input diagnostics")
struct RelayInputDiagnosticSamplerTests {
    @Test func resumesAfterEveryWindow() {
        var sampler = RelayInputDiagnosticSampler()
        for window in 0..<100 {
            for event in 0..<20 {
                let result = sampler.admit(paneID: "pane", name: "key-down",
                    now: Double(window * 5))
                #expect(result == (event < 4))
            }
        }
    }
    @Test func totalAdmissionIsBoundedAcrossPanes() {
        var sampler = RelayInputDiagnosticSampler()
        var accepted = 0
        for event in 0..<100_000 {
            if sampler.admit(paneID: String(event), name: "key-down", now: 0) { accepted += 1 }
        }
        #expect(accepted == 128)
        let resumed = sampler.admit(paneID: "later", name: "key-down", now: 5)
        #expect(resumed)
    }
    @Test func paneAndEventSamplesAreIndependent() {
        var sampler = RelayInputDiagnosticSampler()
        for _ in 0..<4 {
            let admitted = sampler.admit(paneID: "a", name: "key", now: 0)
            #expect(admitted)
        }
        let blocked = !sampler.admit(paneID: "a", name: "key", now: 0)
        #expect(blocked)
        let otherPane = sampler.admit(paneID: "b", name: "key", now: 0)
        #expect(otherPane)
        let otherEvent = sampler.admit(paneID: "a", name: "send", now: 0)
        #expect(otherEvent)
    }

    @Test func repeatingIdleEventsSampleOncePerPanePerMinute() {
        var sampler = RelayInputDiagnosticSampler()
        let name = "prompt-history-suspend"
        func admit(_ pane: String, _ event: String, _ now: TimeInterval) -> Bool {
            sampler.admit(paneID: pane, name: event, now: now)
        }
        let first = admit("a", name, 0)
        #expect(first)
        // Repeats are held across five-second windows until the minute is up.
        let held = [0.0, 1, 5, 30, 59.9].map { admit("a", name, $0) }
        #expect(held == [false, false, false, false, false])
        let otherPane = admit("b", name, 1)
        #expect(otherPane)
        // Other events keep the usual four per window.
        let keys = (0..<6).map { _ in admit("a", "key-down", 2) }.filter { $0 }.count
        #expect(keys == 4)
        let nextMinute = admit("a", name, 60)
        let afterNext = admit("a", name, 61)
        #expect(nextMinute && !afterNext)
        // 26 reconnecting panes over ten minutes: one sample per pane per minute.
        var flood = RelayInputDiagnosticSampler()
        var admitted = 0
        for second in stride(from: 0.0, to: 600, by: 0.5) {
            for pane in 0..<26 where flood.admit(paneID: "p\(pane)", name: name, now: second) { admitted += 1 }
        }
        #expect(admitted == 26 * 10)
    }

    @Test func journalKeepsCountsAndRejectsText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.jsonl")
        let diagnostics = RelayDiagnostics(inputLogURL: url)
        diagnostics.record(category: "terminal-input", name: "insert-text", details: [
            "pane_id": "fixture", "bytes": "12", "characters": "4",
            "terminal_report": "focus_multiple", "acknowledged": "true", "line": "8445",
            "text": "private-draft-marker", "clipboard": "private-clipboard-marker"
        ])
        diagnostics.record(category: "terminal-input", name: "bad-count", details: [
            "pane_id": "fixture", "bytes": "private-content-marker", "characters": "-1",
            "terminal_report": "private-content-marker \u{001B}[<35;12;4M", "acknowledged": "private-content-marker",
            "line": "private-content-marker"
        ])
        diagnostics.flushInputLog()
        let data = try Data(contentsOf: url)
        let content = String(decoding: data, as: UTF8.self)
        #expect(!content.contains("private-"))
        #expect(!content.contains("12;4"))
        let recorded = diagnostics.snapshot().events
        #expect(recorded.allSatisfy { !$0.details.values.contains { $0.contains("private-") } })
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(RelayDiagnosticEvent.self, from: Data(lines[0].utf8))
        let second = try decoder.decode(RelayDiagnosticEvent.self, from: Data(lines[1].utf8))
        #expect(first.details["bytes"] == "12")
        #expect(first.details["characters"] == "4")
        #expect(first.details["terminal_report"] == "focus_multiple")
        #expect(first.details["acknowledged"] == "true")
        #expect(first.details["line"] == "8445")
        #expect(second.details["bytes"] == nil)
        #expect(second.details["characters"] == nil)
        #expect(second.details["terminal_report"] == nil)
        #expect(second.details["acknowledged"] == nil)
        #expect(second.details["line"] == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func journalRotatesAtBoundAndKeepsThreeArchives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("input.jsonl")
        try Data(repeating: 65, count: 1_048_576).write(to: url)
        for index in 1...3 { try Data("archive\(index)".utf8).write(to: url.appendingPathExtension(String(index))) }
        let diagnostics = RelayDiagnostics(inputLogURL: url)
        diagnostics.record(category: "terminal-input", name: "key-down", details: ["pane_id": "fixture"])
        diagnostics.flushInputLog()
        #expect(try Data(contentsOf: url.appendingPathExtension("1")).count == 1_048_576)
        #expect(try String(contentsOf: url.appendingPathExtension("2"), encoding: .utf8) == "archive1")
        #expect(try String(contentsOf: url.appendingPathExtension("3"), encoding: .utf8) == "archive2")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("4").path))
        #expect(try Data(contentsOf: url).count < 1_048_576)
    }
}
