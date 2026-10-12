import Foundation
import Testing
@testable import Relay

@Test func humanRConsoleCommandContainsOnlyOriginalCode() throws {
    let code = "# λ\nx <- 1\nprint(x)"
    let human = RDirectExecution(id: UUID(), sessionID: "R", code: code, humanConsole: true)
    #expect(try human.command(code: code) == code)
    #expect(human.receipt["completion_evidence"] as? String == "none")
    #expect(human.receipt["completion"] as? String == "unknown")
    #expect(human.receipt["code"] as? String == code)
    let restored = try JSONDecoder().decode(RDirectExecution.self, from: JSONEncoder().encode(human))
    #expect(try restored.command(code: code) == code)
    let agent = RDirectExecution(id: UUID(), sessionID: "R", code: code)
    #expect(try agent.command(code: code) != code)
}

@Test func rProjectSnapshotRejectsChangedBytesAndInvalidEncoding() throws {
    let code = "x <- 'λ'\nprint(x)\n"
    let hash = RExecutionSource.digest(code)
    let snapshot = try RProjectExecutionSnapshot.capture(Data(code.utf8), path: "/project/a.R", expectedSHA256: hash)
    #expect(snapshot.code == code)
    #expect(snapshot.source.kind == "disk_snapshot")
    #expect(snapshot.source.documentSHA256 == hash)
    #expect(throws: (any Error).self) {
        try RProjectExecutionSnapshot.capture(Data((code + "# changed").utf8), path: "/project/a.R", expectedSHA256: hash)
    }
    #expect(throws: (any Error).self) {
        try RProjectExecutionSnapshot.capture(Data([0xff]), path: "/project/a.R", expectedSHA256: hash)
    }
}

@Test func rDirectReceiptRetainsExactSourceAndDecodesLegacyRecord() throws {
    let code = "x <- 'λ'\nstop('after mutation')"
    var record = RDirectExecution(id: UUID(), sessionID: "session", code: code)
    #expect(record.receipt["code"] as? String == code)
    #expect(record.source?.codeSHA256 == RExecutionSource.digest(code))
    #expect(throws: (any Error).self) { try record.command(code: code + "\n") }
    _ = record.receive(record.marker("started"))
    _ = record.receive(record.marker("error"))
    #expect(record.receipt["state_may_be_partially_changed"] as? Bool == true)
    let restored = try JSONDecoder().decode(RDirectExecution.self, from: JSONEncoder().encode(record))
    #expect(restored.codeSnapshot == code)
    #expect(restored.source == record.source)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    legacy.removeValue(forKey: "source")
    legacy.removeValue(forKey: "codeSnapshot")
    let old = try JSONDecoder().decode(RDirectExecution.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.codeSnapshot == nil)
    #expect(old.source == nil)
}

@Test func rDirectMarkersRejectEchoAndSurviveSplitFrames() throws {
    var record = RDirectExecution(id: UUID(), sessionID: "r-session")
    let command = try record.command(code: "print(21)")
    #expect(!command.contains("relay_r_evaluate"))
    #expect(!command.contains("relay_r_"))
    let received1 = record.receive(Data(command.utf8))
    #expect(!received1)
    let received2 = record.receive(record.marker("started"))
    #expect(!received2)
    let received3 = record.receive(Data("[1] 21\n".utf8))
    #expect(!received3)
    let end = record.marker("completed")
    let received4 = record.receive(end.prefix(7))
    #expect(!received4)
    let received5 = record.receive(end.dropFirst(7))
    #expect(received5)
    #expect(record.status == "completed")
    #expect(String(decoding: record.output, as: UTF8.self) == "[1] 21\n")
    let received6 = record.receive(record.marker("error"))
    #expect(!received6)
}

@Test func rDirectExecutionPreservesLargeCodeAndDistinguishesError() throws {
    var record = RDirectExecution(id: UUID(), sessionID: "r-session")
    let code = String(repeating: "# λ \"quoted\"\n", count: 2000) + "stop('expected')"
    let command = try record.command(code: code)
    #expect(command.utf8.count < 128 << 10)
    #expect(command.split(separator: "\n").allSatisfy { $0.utf8.count < 4096 })
    let received7 = record.receive(record.marker("started"))
    #expect(!received7)
    let received8 = record.receive(Data("expected\n".utf8))
    #expect(!received8)
    let received9 = record.receive(record.marker("error"))
    #expect(received9)
    #expect(record.status == "error")
    let restored = try JSONDecoder().decode(RDirectExecution.self, from: JSONEncoder().encode(record))
    #expect(restored.nonce == record.nonce)
    #expect(restored.status == "error")
}

@Test func rDirectRestartAcceptsExactEndWithoutOldOutput() {
    var record = RDirectExecution(id: UUID(), sessionID: "r-session")
    var snapshot = Data("old unrelated console output\n".utf8)
    snapshot.append(record.marker("completed"))
    let complete = record.receive(snapshot)
    #expect(complete)
    #expect(record.output.isEmpty)
    #expect(record.status == "completed")
}
