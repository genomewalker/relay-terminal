import Foundation
import Testing
@testable import Relay

@Test func privateOperationJournalRecoversWithoutRepeatingConsumer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("receipts.json"), id = UUID()
    let owner = RelayPrivateOperationJournal.digest(["host", "pane", "session"])
    let request = RelayPrivateOperationJournal.digest(["public destination"])
    let journal = RelayPrivateOperationJournal(url: url)
    try journal.admit(id, owner: owner, request: request)
    #expect(try RelayPrivateOperationJournal(url: url).lookup(id, owner: owner) == "outcome_unknown")
    #expect(throws: (any Error).self) { try journal.admit(id, owner: owner, request: request) }
    #expect(throws: (any Error).self) { try journal.finish(id, status: "completed") }
    try journal.finish(id, status: "running")
    #expect(try RelayPrivateOperationJournal(url: url).lookup(id, owner: owner) == "outcome_unknown")
    try journal.finish(id, status: "completed")
    let recovered = RelayPrivateOperationJournal(url: url)
    #expect(try recovered.lookup(id, owner: owner, request: request) == "completed")
    #expect(throws: (any Error).self) { try recovered.lookup(id, owner: "different session") }
    #expect(throws: (any Error).self) { try recovered.lookup(id, owner: owner, request: "different destination") }
}

@Test func privateOperationJournalFailsClosedOnFullCorruptOrUnwritableStorage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("receipts.json")
    let journal = RelayPrivateOperationJournal(url: url, limit: 1)
    try journal.admit(UUID(), owner: "owner", request: "request")
    #expect(throws: (any Error).self) { try journal.admit(UUID(), owner: "owner", request: "request") }
    try Data("corrupt".utf8).write(to: url)
    #expect(throws: (any Error).self) { try RelayPrivateOperationJournal(url: url).admit(UUID(), owner: "owner", request: "request") }
    let notDirectory = directory.appendingPathComponent("file")
    try Data().write(to: notDirectory)
    #expect(throws: (any Error).self) {
        try RelayPrivateOperationJournal(url: notDirectory.appendingPathComponent("receipt")).admit(UUID(), owner: "owner", request: "request")
    }
}

@Test func privateOperationJournalReloadsSeparateControllersBeforeAdmission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("receipts.json")
    let first = RelayPrivateOperationJournal(url: url), second = RelayPrivateOperationJournal(url: url)
    let firstID = UUID(), secondID = UUID()
    try first.admit(firstID, owner: "owner", request: "first")
    try second.admit(secondID, owner: "owner", request: "second")
    #expect(try first.lookup(secondID, owner: "owner") == "outcome_unknown")
    #expect(try second.lookup(firstID, owner: "owner") == "outcome_unknown")
    #expect(throws: (any Error).self) { try second.admit(firstID, owner: "owner", request: "first") }
}
