import Foundation
import Testing
@testable import Relay

private func pem(_ bytes: [UInt8]) -> String {
    "-----BEGIN CERTIFICATE-----\n" + Data(bytes).base64EncodedString() + "\n-----END CERTIFICATE-----\n"
}

@MainActor
private final class FakeHosts {
    var identities: [UUID: [String: Any]] = [:]
    var pushed: [UUID: [[String: Any]]] = [:]
    var calls: [String] = []

    func identity(_ host: UUID, node: String, certificate: String, fingerprint: String? = nil, authority: String = "relayd") {
        identities[host] = ["node_id": node, "certificate_pem": certificate,
            "certificate_sha256": fingerprint ?? RelayNodeTrust.certificateFingerprint(certificate)!, "authority": authority]
    }

    func request(_ profile: ConnectionProfile, _ packet: [String: Any]) async throws -> [String: Any] {
        let operation = packet["operation"] as? String ?? ""
        calls.append(operation)
        switch operation {
        case "node_identity":
            guard let identity = identities[profile.id] else { throw RemoteCatalogError.failed("unreachable") }
            return identity
        case "node_trust_set":
            pushed[profile.id] = packet["trusted_nodes"] as? [[String: Any]] ?? []
            return ["authority": "relayd"]
        default:
            throw RemoteCatalogError.failed("unexpected operation")
        }
    }
}

@MainActor
private func trustFixture() -> (RelayNodeTrust, FakeHosts, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-node-trust-\(UUID().uuidString)")
    let hosts = FakeHosts()
    let trust = RelayNodeTrust(directory: directory, request: { profile, packet in try await hosts.request(profile, packet) })
    return (trust, hosts, directory)
}

private func relayHost(_ name: String) -> ConnectionProfile {
    var profile = ConnectionProfile.sshConfigHost(name)
    profile.backend = .relay
    return profile
}

@MainActor
@Test("A host key is pinned on first use and a changed key is never adopted silently")
func nodeTrustPinsOnFirstUseOnly() async throws {
    let (trust, hosts, directory) = trustFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = relayHost("dandy-07")
    hosts.identity(host.id, node: "aaaaaaaaaaaaaaaa", certificate: pem([1, 2, 3]))
    let pin = try await trust.observe(host)
    #expect(pin.nodeID == "aaaaaaaaaaaaaaaa")

    hosts.identity(host.id, node: "aaaaaaaaaaaaaaaa", certificate: pem([9, 9, 9]))
    await #expect(throws: RelayNodeTrust.TrustError.identityChanged(host: host.id)) { try await trust.observe(host) }
    #expect(trust.pins[host.id] == pin)
    #expect(trust.mismatches[host.id] != nil)
    await #expect(throws: RelayNodeTrust.TrustError.identityChanged(host: host.id)) { try await trust.push(to: host) }

    // A new key under a different host ID is also a change, not a new host.
    hosts.identity(host.id, node: "cccccccccccccccc", certificate: pem([1, 2, 3]))
    await #expect(throws: RelayNodeTrust.TrustError.identityChanged(host: host.id)) { try await trust.observe(host) }

    // Only an explicit owner confirmation adopts it, and it persists.
    hosts.identity(host.id, node: "aaaaaaaaaaaaaaaa", certificate: pem([9, 9, 9]))
    _ = try? await trust.observe(host)
    try trust.confirmChangedIdentity(host: host.id)
    #expect(trust.pins[host.id]?.certificateSHA256 == RelayNodeTrust.certificateFingerprint(pem([9, 9, 9])))
    let reloaded = RelayNodeTrust(directory: directory, request: { _, _ in [:] })
    #expect(reloaded.pins[host.id] == trust.pins[host.id])
    let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("pins.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@MainActor
@Test("Identities that do not prove their own fingerprint are refused")
func nodeTrustRejectsInvalidIdentities() async throws {
    let (trust, hosts, directory) = trustFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = relayHost("dandy-07")
    for (node, certificate, fingerprint, authority) in [
        ("aaaaaaaaaaaaaaaa", pem([1, 2, 3]), String(repeating: "0", count: 64), "relayd"),
        ("aaaaaaaaaaaaaaaa", pem([1, 2, 3]), nil, "desktop"),
        ("../etc", pem([1, 2, 3]), nil, "relayd"),
        ("aaaaaaaaaaaaaaaa", "-----BEGIN PUBLIC KEY-----\nAQID\n-----END PUBLIC KEY-----\n", String(repeating: "0", count: 64), "relayd"),
        ("aaaaaaaaaaaaaaaa", pem([1]) + pem([2]), String(repeating: "0", count: 64), "relayd"),
    ] as [(String, String, String?, String)] {
        hosts.identities[host.id] = ["node_id": node, "certificate_pem": certificate,
            "certificate_sha256": fingerprint ?? RelayNodeTrust.certificateFingerprint(certificate) ?? "", "authority": authority]
        await #expect(throws: RelayNodeTrust.TrustError.self) { try await trust.observe(host) }
    }
    #expect(trust.pins.isEmpty)
}

@MainActor
@Test("Each host receives every other pinned host once, never itself")
func nodeTrustPushesOthersOnly() async throws {
    let (trust, hosts, directory) = trustFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mac = relayHost("mac"), dandy = relayHost("dandy-07"), alias = relayHost("dandy-07-alias")
    hosts.identity(mac.id, node: "aaaaaaaaaaaaaaaa", certificate: pem([1]))
    hosts.identity(dandy.id, node: "bbbbbbbbbbbbbbbb", certificate: pem([2]))
    // A second profile for the same host carries the same key.
    hosts.identity(alias.id, node: "bbbbbbbbbbbbbbbb", certificate: pem([2]))
    let failures = await trust.refresh(profiles: [mac, dandy, alias])
    #expect(failures.isEmpty)
    let toDandy = hosts.pushed[dandy.id] ?? []
    #expect(toDandy.map { $0["node_id"] as? String } == ["aaaaaaaaaaaaaaaa"])
    let toMac = hosts.pushed[mac.id] ?? []
    #expect(toMac.map { $0["node_id"] as? String } == ["bbbbbbbbbbbbbbbb"])
    #expect(toMac.allSatisfy { $0["signs_messages"] as? Bool == true })
}

@MainActor
@Test("A host that cannot be reached is reported, not pushed, and leaves others intact")
func nodeTrustRefreshReportsFailures() async throws {
    let (trust, hosts, directory) = trustFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mac = relayHost("mac"), down = relayHost("down")
    hosts.identity(mac.id, node: "aaaaaaaaaaaaaaaa", certificate: pem([1]))
    let failures = await trust.refresh(profiles: [mac, down])
    #expect(failures[down.id] != nil && failures[mac.id] == nil)
    #expect(hosts.pushed[down.id] == nil && hosts.pushed[mac.id] != nil)
}

@Test("Only refusals made before any write let a send try another path")
func signedDeliveryFallbackClassification() {
    for declined in ["relayd: signing host is not trusted on this host", "relayd: malformed signed envelope",
                     "relayd: session certificate expired or outside host validity", "relayd: message signature invalid",
                     "relayd: signed statement does not match this delivery", "relayd: signed statement expired",
                     "relayd: unknown daemon communication operation"] {
        #expect(RelayPaneMessaging.signedDeliveryDeclinedBeforeWrite(declined), "\(declined)")
    }
    for ambiguous in ["relayd: message identity conflicts with a previous request", "Connection reset by peer",
                      "The communication daemon is unavailable", "relayd: communication record exceeds limit",
                      "Timed out waiting for the host", ""] {
        #expect(!RelayPaneMessaging.signedDeliveryDeclinedBeforeWrite(ambiguous), "\(ambiguous)")
    }
}

@Test("A forwarded signature never changes message identity")
func signatureIsNotMessageIdentity() throws {
    let base = RelayPaneMessaging.Request(sourcePaneID: UUID(), messageID: UUID(), text: "hello")
    var signed = base
    signed.sourceSignature = "eyJ2IjoxfQ"
    let decoded = try JSONDecoder().decode(RelayPaneMessaging.Request.self,
        from: Data(#"{"sourcePaneID":"\#(base.sourcePaneID)","messageID":"\#(base.messageID)","text":"hello","sourceSignature":"eyJ2IjoxfQ"}"#.utf8))
    #expect(decoded.sourceSignature == "eyJ2IjoxfQ")
    #expect(decoded.sourcePaneID == base.sourcePaneID && decoded.text == base.text)
}

@MainActor
@Test("A stale key pinned for a host's own node ID is never pushed back to it")
func nodeTrustNeverPushesHostItsOwnNode() async throws {
    let (trust, hosts, directory) = trustFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mac = relayHost("mac"), dandy = relayHost("dandy-07"), oldDandy = relayHost("dandy-07-before-rotation")
    hosts.identity(mac.id, node: "aaaaaaaaaaaaaaaa", certificate: pem([1]))
    hosts.identity(dandy.id, node: "bbbbbbbbbbbbbbbb", certificate: pem([2]))
    // Another profile still pins dandy's node with its pre-rotation key.
    hosts.identity(oldDandy.id, node: "bbbbbbbbbbbbbbbb", certificate: pem([3]))
    _ = await trust.refresh(profiles: [mac, dandy, oldDandy])
    let toDandy = hosts.pushed[dandy.id] ?? []
    #expect(toDandy.map { $0["node_id"] as? String } == ["aaaaaaaaaaaaaaaa"])
}
