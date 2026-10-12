import Foundation
import CryptoKit
import Testing

@Test("New local profiles use durable Relay transport and retain it when saved")
func localDurableProfile() throws {
    let profile = ConnectionProfile.local
    #expect(profile.kind == .local)
    #expect(profile.backend == .relay)
    let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
    #expect(restored.backend == .relay)
}

@Test("Native R input preserves code and rejects oversized or terminal-control input")
func rUserInput() throws {
    #expect(try RWorkspaceCommand.userInput("x <- 1\r\nplot(x)") == "x <- 1\nplot(x)")
    #expect(throws: (any Error).self) { try RWorkspaceCommand.userInput("\u{1b}[2J") }
    #expect(throws: (any Error).self) { try RWorkspaceCommand.userInput(String(repeating: "x", count: 65537)) }
}

@Test("File-based R setup stays short and verifies the installed companion")
func rFileSetupCommand() throws {
    let command = try RWorkspaceCommand.setupFile(path: "/tmp/a b/companion.R", md5: String(repeating: "a", count: 32), root: "/tmp/results")
    #expect(command.utf8.count < 2048)
    #expect(command.split(separator: "\n").allSatisfy { $0.utf8.count < 4096 })
    #expect(command.contains("tools::md5sum"))
    #expect(command.contains("sys.source"))
    #expect(command.contains("relay_r_httpgd_start"))
    #expect(command.contains("relay_r_console_start"))
    #expect(throws: (any Error).self) { try RWorkspaceCommand.setupFile(path: "relative.R", md5: "bad", root: "/tmp") }
    #expect(throws: (any Error).self) { try RWorkspaceCommand.setupFile(path: "/" + String(repeating: "x", count: 3000), md5: String(repeating: "a", count: 32), root: "/tmp") }
}
@testable import Relay

@Test("Automatic R result display accepts only known completed artifact names")
func rWorkspaceAutomaticArtifacts() throws {
    func receipt(_ fields: String) throws -> RExecutionSnapshot {
        try JSONDecoder().decode(RExecutionSnapshot.self, from: Data(("{\"request_id\":\"r\",\"session_id\":\"s\"," + fields + "}").utf8))
    }
    #expect(try receipt("\"status\":\"completed\",\"table\":{\"artifact\":\"table.csv\"}").displayArtifact == "table.csv")
    #expect(try receipt("\"status\":\"completed\",\"plots\":[\"plot-001.png\",\"plot-002.png\"]").displayArtifact == "plot-002.png")
    #expect(try receipt("\"status\":\"running\",\"plots\":[\"plot-001.png\"]").displayArtifact == nil)
    #expect(try receipt("\"status\":\"completed\",\"table\":{\"artifact\":\"../private.csv\"},\"plots\":[\"../plot-001.png\"]").displayArtifact == nil)
}

@Test("R result tabs preserve their own export when another result refreshes")
func rWorkspaceIndependentArtifacts() {
    var artifacts = RResultArtifacts()
    artifacts.store(section: "Plots", path: "console-latest.png", bytes: Data([1]))
    artifacts.store(section: "Table", path: "request/table.csv", bytes: Data([2]))
    artifacts.store(section: "Environment", path: "environment.json", bytes: Data([3]))
    #expect(artifacts["Plots"]?.path == "console-latest.png")
    #expect(artifacts["Plots"]?.bytes == Data([1]))
    #expect(artifacts["Table"]?.bytes == Data([2]))
    artifacts.store(section: "Plots", path: "plot-002.png", bytes: Data([4]))
    #expect(artifacts["Table"]?.path == "request/table.csv")
    #expect(artifacts["Plots"]?.bytes == Data([4]))
    artifacts.store(section: "unknown", path: "other", bytes: Data([5]))
    #expect(artifacts["unknown"] == nil)
    artifacts = RResultArtifacts()
    #expect(artifacts["Plots"] == nil)
    #expect(artifacts["Table"] == nil)
}

@Test("R result reads cannot cross a session or presentation invalidation")
func rWorkspaceResultReadGeneration() {
    var gate = RResultReadGate()
    let old = gate.generation
    #expect(gate.accepts(old))
    gate.invalidate()
    #expect(!gate.accepts(old))
    let current = gate.generation
    #expect(gate.accepts(current))
    gate.invalidate()
    #expect(!gate.accepts(old))
    #expect(!gate.accepts(current))
}

@Test("R execution is bound to the reviewed process and preserves literal code")
func rWorkspaceCommands() throws {
    let session = RWorkspaceSession(version: 1, session_id: "unique", pid: 1, host: "host", working_directory: "/tmp", artifact_root: "/tmp/results", capabilities: ["evaluate"])
    let command = try RWorkspaceCommand.evaluate(code: "x <- 'λ';\nprint(x)", id: UUID(), root: "/tmp/results", session: session)
    #expect(command.contains("expected_session=\"unique\""))
    #expect(command.split(separator: "\n").allSatisfy { $0.utf8.count < 4096 })
    #expect(throws: (any Error).self) { try RWorkspaceCommand.evaluate(code: "1", id: UUID(), root: "/other", session: session) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("remote/r/relay-r.R"), encoding: .utf8)
    let setup = try RWorkspaceCommand.setup(source: source, root: "/tmp/results")
    #expect(AgentInputProposal(instance: UUID(), requestID: UUID(), text: setup).isValid)
    #expect(setup.contains("\n"))
    #expect(setup.contains("relay_r_httpgd_start"))
    #expect(setup.contains("else relay_r_console_start"))
    #expect(setup.split(separator: "\n").allSatisfy { $0.utf8.count < 4096 })
    let chunkLines = setup.components(separatedBy: "\n").filter { $0.hasPrefix("\"") }
    let reconstructed = try chunkLines.map { line in
        let json = line.hasSuffix(",") ? String(line.dropLast()) : line
        return try JSONDecoder().decode(String.self, from: Data(json.utf8))
    }.joined()
    #expect(reconstructed == source)
}

@Test func rLargeEditorSelectionUsesShortLosslessLines() throws {
    let root = "/tmp/results"
    let session = RWorkspaceSession(version: 1, session_id: "test", pid: 123, host: "host", working_directory: "/tmp", artifact_root: root, capabilities: ["evaluate"])
    let code = String(repeating: "# λ \"quoted\"\n", count: 3000)
    let command = try RWorkspaceCommand.evaluate(code: code, id: UUID(), root: root, session: session)
    #expect(code.utf8.count > 4096)
    #expect(command.utf8.count < 128 << 10)
    #expect(command.split(separator: "\n").allSatisfy { $0.utf8.count < 4096 })
    let chunks = command.split(separator: "\n").filter { $0.hasPrefix("\"") }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\",")) }.joined()
    #expect(Data(base64Encoded: chunks) == Data(code.utf8))
    #expect(throws: (any Error).self) { try RWorkspaceCommand.userInput(String(repeating: "a", count: 65537)) }
}
