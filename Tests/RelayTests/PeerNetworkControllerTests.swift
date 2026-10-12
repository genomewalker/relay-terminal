import Foundation
import Testing
@testable import Relay

private func validPeerConfiguration() -> PeerLinkConfiguration {
    var c = PeerLinkConfiguration()
    c.host = "test-host"; c.localName = "codex-local"; c.localSession = "session-a"
    c.localPID = "123"; c.remoteName = "claude-remote"; c.remoteSession = "session-b"
    c.remotePID = "456"; c.remoteLabel = "remote"
    return c
}

@Test("Peer link configuration rejects shell syntax and missing identity")
func peerLinkConfigurationValidation() {
    let good = validPeerConfiguration()
    #expect(good.validationError == nil)
    #expect(good.arguments.contains("--remote-pid"))
    var pinned = good
    pinned.remoteStart = "Tue Sep 29 07:04:09 2026"
    #expect(pinned.validationError == nil)
    #expect(pinned.arguments.suffix(2).elementsEqual(["--remote-start", "Tue Sep 29 07:04:09 2026"]))
    for bad in ["x;touch /tmp/x", "-oProxyCommand=bad", "space name", ""] {
        var c = good; c.host = bad
        #expect(c.validationError != nil)
    }
    var c = good; c.remotePID = "-1"
    #expect(c.validationError != nil)
    c = good; c.remoteBinary = "$(command)"
    #expect(c.validationError != nil)
}

@Test("Failed link saves preserve configurations and duplicate IDs are rejected")
@MainActor func peerLinkSaveFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // A file where a directory belongs deterministically forces persistence failure.
    try Data().write(to: root)
    let blocked = PeerNetworkController(root: root)
    let configuration = validPeerConfiguration()
    #expect(!blocked.save(configuration))
    #expect(blocked.configurations.isEmpty)
    #expect(blocked.error != nil)
    try FileManager.default.removeItem(at: root)
    #expect(blocked.save(configuration))
    #expect(blocked.error == nil)
    var collision = configuration
    collision.remoteSession = "different-session"
    #expect(!blocked.save(collision))
    #expect(blocked.configurations == [configuration])
    #expect(PeerNetworkController(root: root).configurations == [configuration])
}

@Test("Saving link configuration does not launch a process and preserves identities")
@MainActor func peerLinkConfigurationPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = PeerNetworkController(root: root)
    let configuration = validPeerConfiguration()
    controller.save(configuration)
    #expect(controller.error == nil)
    #expect(controller.running.isEmpty)
    let loaded = PeerNetworkController(root: root)
    #expect(loaded.configurations == [configuration])
    loaded.save(configuration)
    #expect(loaded.configurations.count == 1)
    #expect(loaded.error != nil)
    loaded.remove(configuration)
    #expect(PeerNetworkController(root: root).configurations.isEmpty)
}
