import Foundation
import Testing
@testable import Relay

struct RelayAccountForceJournalTests {
    private func preview() -> RelayAccountForcePreview {
        .init(host: "This Mac", paneID: UUID(), provider: "claude", sessionID: "session",
              providerPID: 123, providerStart: "456", blockerPID: 789, blockerStart: "1011",
              commandDigest: String(repeating: "a", count: 64), arguments: ["bash", "-c", "work"])
    }

    @Test("One process incarnation cannot be reserved twice even with a fresh action ID")
    func reservationSurvivesNewInstance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-force-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let value = preview()
        try RelayAccountForceJournal(directory: dir).reserve(preview: value, actionID: UUID())
        #expect(throws: RelayAccountForceJournal.Failure.self) {
            try RelayAccountForceJournal(directory: dir).reserve(preview: value, actionID: UUID())
        }
    }

    @Test("A symlink cannot be used as the private force journal directory")
    func refusesSymlinkDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("relay-force-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) {
            try RelayAccountForceJournal(directory: link).reserve(preview: preview(), actionID: UUID())
        }
    }

    @Test("An uncertain dispatch cannot be repeated, even if the lease callback is invoked twice")
    @MainActor func uncertainDispatchIsSingleUse() async {
        enum Failure: Error { case responseLost }
        let action = RelayAccountForceTransaction(preview: preview())
        var calls = 0
        let first = await action.run(withLease: { execute in
            let result = await execute()
            _ = await execute()
            return result
        }, dispatch: { _, _ in
            calls += 1
            throw Failure.responseLost
        })
        let retry = await action.run(withLease: { execute in await execute() }, dispatch: { _, _ in
            calls += 1
            return "exited"
        })
        #expect(first == .unknown)
        #expect(retry == .refused)
        #expect(calls == 1)
    }

    @Test("A force target needs a fresh matching provider workspace")
    @MainActor func destinationRequiresVerifiedWorkspace() throws {
        let target = RelayAgentAccount(provider: "claude", label: "business", dir: "~/.claude-team")
        func status(_ workspace: String, _ key: String, _ probe: String) throws -> RelayAgentAccountStatus {
            let json: [String: Any] = ["provider": "claude", "label": "business", "dir": "~/.claude-team",
                "root": "/tmp/team", "default": false, "exists": true, "logged_in": "yes", "probe": probe,
                "workspace": workspace, "workspace_key": key, "expect_workspace": "AEGIS-micro"]
            return try JSONDecoder().decode(RelayAgentAccountStatus.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(RelayAccountForcePicker.checkedDestination([try status("AEGIS-micro", "1234567890abcdef", "ok")], target: target) != nil)
        #expect(RelayAccountForcePicker.checkedDestination([try status("other", "1234567890abcdef", "ok")], target: target) == nil)
        #expect(RelayAccountForcePicker.checkedDestination([try status("AEGIS-micro", "", "ok")], target: target) == nil)
        #expect(RelayAccountForcePicker.checkedDestination([try status("AEGIS-micro", "1234567890abcdef", "failed")], target: target) == nil)
    }
}
