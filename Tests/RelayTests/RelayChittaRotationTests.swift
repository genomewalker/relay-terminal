import Foundation
import Testing
@testable import Relay

struct RelayChittaRotationTests {
    @Test func exactDurableCapsuleRequiredBeforeRotation() {
        let identity = RelaySupervisedSessionID(paneID: UUID(), sessionID: "codex-session", generation: 7)
        let signal = RelayChittaRotationSignal(schema: 1, eventID: "event-1",
            sessionID: identity.sessionID, action: "rotate", capsuleRequired: true,
            rotationRequested: true, lifecyclePerformed: false)
        let capsule = RelayChittaCapsule(version: 2, sessionID: identity.sessionID,
            projectDir: "/work/project", codeHead: String(repeating: "a", count: 40),
            revision: 4, state: "in_progress", objective: "Finish repair",
            nextAction: "Run the focused check")
        func admitted(_ signal: RelayChittaRotationSignal = signal,
                      _ read: RelayChittaCapsuleRead = RelayChittaCapsuleRead(status: "ok", capsule: capsule),
                      head: String = String(repeating: "a", count: 40), idle: Bool = true) -> Bool {
            RelayChittaRotationGate.admits(signal: signal, capsule: read, identity: identity,
                projectDir: "/work/project", codeHead: head, turnIdle: idle)
        }
        #expect(admitted())
        #expect(!admitted(idle: false))
        #expect(!admitted(head: String(repeating: "b", count: 40)))
        #expect(!admitted(signal, RelayChittaCapsuleRead(status: "stale", capsule: capsule)))
        #expect(!admitted(signal, RelayChittaCapsuleRead(status: "head_mismatch", capsule: capsule)))
        #expect(!admitted(RelayChittaRotationSignal(schema: 1, eventID: "event-1",
            sessionID: identity.sessionID, action: "prepare", capsuleRequired: true,
            rotationRequested: false, lifecyclePerformed: false)))
        #expect(!admitted(RelayChittaRotationSignal(schema: 1, eventID: "event-1",
            sessionID: "another-session", action: "rotate", capsuleRequired: true,
            rotationRequested: true, lifecyclePerformed: false)))
    }
}
