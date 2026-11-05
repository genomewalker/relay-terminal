import Foundation
import Testing
@testable import Relay

@Suite("Connection journal")
struct RelayConnectionJournalTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func connectionEventsReachDiskRedactedAndPrivate() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("connection.jsonl")
        let diagnostics = RelayDiagnostics(inputLogURL: directory.appendingPathComponent("input.jsonl"),
                                           connectionLogURL: url)
        diagnostics.record(category: "connection", name: "disconnected", details: [
            "connection_id": "node-1", "reason": "auth Bearer must-not-survive", "retry": "true",
        ])
        diagnostics.record(category: "pane", name: "reconnecting", details: ["pane_id": "fixture"])
        diagnostics.record(category: "network", name: "peer-discovery-failed", details: ["host": "This Mac"])
        diagnostics.record(category: "app", name: "launched")
        // Other categories stay in memory only.
        diagnostics.record(category: "snapshot", name: "restored")
        diagnostics.record(category: "assistant", name: "turn")
        diagnostics.flushInputLog()

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("must-not-survive"))
        let names = diagnostics.connectionJournal().map(\.name)
        #expect(names == ["disconnected", "reconnecting", "peer-discovery-failed", "launched"])
        #expect(diagnostics.connectionJournal().first?.details["retry"] == "true")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.jsonl").path))
    }

    @Test func aRelaunchedRelayExportsTheEarlierLaunchesEvents() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("connection.jsonl")
        let before = RelayDiagnostics(inputLogURL: directory.appendingPathComponent("input.jsonl"), connectionLogURL: url)
        before.record(category: "connection", name: "ssh-started", details: ["connection_id": "node-7"])
        before.record(category: "connection", name: "disconnected", details: ["connection_id": "node-7"])
        before.flushInputLog()

        // A new process: its in-memory timeline starts empty.
        let after = RelayDiagnostics(inputLogURL: directory.appendingPathComponent("input.jsonl"), connectionLogURL: url)
        #expect(after.snapshot().events.isEmpty)
        let exportURL = directory.appendingPathComponent("export.json")
        try after.export(to: exportURL)
        let bundle = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
        let journal = bundle?["connection_journal"] as? [[String: Any]]
        #expect(journal?.compactMap { $0["name"] as? String } == ["ssh-started", "disconnected"])
        #expect((bundle?["events"] as? [Any])?.isEmpty == true)
    }

    @Test func journalReadsAcrossRotationSkipsTornLinesAndKeepsTheNewest() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("connection.jsonl")
        let diagnostics = RelayDiagnostics(inputLogURL: directory.appendingPathComponent("input.jsonl"), connectionLogURL: url)
        for index in 0..<3 { diagnostics.record(category: "connection", name: "old-\(index)") }
        diagnostics.flushInputLog()
        // A crash mid-write leaves a torn line; then the file reaches the bound.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"20"#.utf8) + Data(repeating: 65, count: 1_048_576))
        try handle.close()
        diagnostics.record(category: "connection", name: "new-0")
        diagnostics.record(category: "connection", name: "new-1")
        diagnostics.flushInputLog()

        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        #expect(diagnostics.connectionJournal().map(\.name) == ["old-0", "old-1", "old-2", "new-0", "new-1"])
        #expect(diagnostics.connectionJournal(limit: 3).map(\.name) == ["old-2", "new-0", "new-1"])
        #expect(diagnostics.connectionJournal(limit: 0).isEmpty)
    }

    @Test func theFirstEventAfterACrashTornLineIsKept() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("connection.jsonl")
        let input = directory.appendingPathComponent("input.jsonl")
        let crashed = RelayDiagnostics(inputLogURL: input, connectionLogURL: url)
        crashed.record(category: "connection", name: "before-crash")
        crashed.flushInputLog()
        // The process dies mid-write: a short torn tail, far below rotation.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"2026-10"#.utf8))
        try handle.close()

        let relaunched = RelayDiagnostics(inputLogURL: input, connectionLogURL: url)
        relaunched.record(category: "app", name: "launched")
        relaunched.record(category: "connection", name: "ssh-started")
        relaunched.flushInputLog()
        #expect(relaunched.connectionJournal().map(\.name) == ["before-crash", "launched", "ssh-started"])
        let exportURL = directory.appendingPathComponent("export.json")
        try relaunched.export(to: exportURL)
        let bundle = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
        let names = (bundle?["connection_journal"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["before-crash", "launched", "ssh-started"])
        // An intact journal gains no blank lines.
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.filter(\.isEmpty).count == 1)
    }

    @Test func testsNeverWriteTheProfilesJournal() {
        // The default journal path is the profile's; under tests it is off.
        let diagnostics = RelayDiagnostics()
        diagnostics.record(category: "connection", name: "ready", details: ["connection_id": "fixture"])
        diagnostics.flushInputLog()
        #expect(diagnostics.connectionJournal().isEmpty)
        #expect(diagnostics.snapshot().events.last?.name == "ready")
    }
}
