import CryptoKit
import Foundation

/// Host signing keys this desktop has pinned, and the trust set it pushes to
/// each host so that host's relayd can verify signed messages from the others.
///
/// A key is pinned the first time a host is seen over its already host-key
/// verified connection. A changed key is never adopted automatically: it is
/// recorded as a mismatch and needs the owner's confirmation.
@MainActor final class RelayNodeTrust {
    static let shared = RelayNodeTrust(directory:
        RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/NodeTrust", isDirectory: true))

    struct Pin: Codable, Equatable, Sendable {
        let hostID: UUID
        let nodeID: String
        let certificatePEM: String
        let certificateSHA256: String
        let pinnedAt: Date
    }

    struct Mismatch: Equatable, Sendable {
        let pinned: Pin
        let offered: Pin
    }

    enum TrustError: LocalizedError, Equatable {
        case invalidIdentity(String)
        case identityChanged(host: UUID)
        case unknownHost

        var errorDescription: String? {
            switch self {
            case .invalidIdentity(let reason): "The host returned an invalid signing identity: \(reason)."
            case .identityChanged: "This host's signing key changed since it was trusted. Confirm the new key before its messages can be verified."
            case .unknownHost: "This host has not been trusted yet."
            }
        }
    }

    /// Runs one communication operation on a host's relayd as the owner.
    typealias Request = @MainActor (ConnectionProfile, [String: Any]) async throws -> [String: Any]

    private(set) var pins: [UUID: Pin] = [:]
    private(set) var mismatches: [UUID: Mismatch] = [:]
    private let directory: URL
    private let request: Request
    private let now: () -> Date

    init(directory: URL, now: @escaping () -> Date = Date.init,
         request: @escaping Request = { profile, packet in try await RelayNodeTrust.daemonRequest(profile: profile, packet: packet) }) {
        self.directory = directory
        self.request = request
        self.now = now
        load()
    }

    private var fileURL: URL { directory.appendingPathComponent("pins.json") }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Pin].self, from: data) else { return }
        pins = Dictionary(saved.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pins.values.sorted { $0.hostID.uuidString < $1.hostID.uuidString })
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// SHA-256 of the DER bytes of exactly one PEM certificate, as relayd computes it.
    nonisolated static func certificateFingerprint(_ pem: String) -> String? {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "-----BEGIN CERTIFICATE-----", lines.last == "-----END CERTIFICATE-----",
              lines.filter({ $0.hasPrefix("-----") }).count == 2, pem.utf8.count <= 8192,
              let der = Data(base64Encoded: lines.dropFirst().dropLast().joined()), !der.isEmpty else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func validNodeID(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9_-]{1,96}$"#, options: .regularExpression) != nil
    }

    /// Fetches the host's identity and pins it on first use. Returns the pin,
    /// or throws `identityChanged` if it differs from the pinned key.
    @discardableResult
    func observe(_ profile: ConnectionProfile) async throws -> Pin {
        let offered = try await identify(profile)
        let node = offered.nodeID, computed = offered.certificateSHA256
        if let pinned = pins[profile.id] {
            guard pinned.certificateSHA256 == computed, pinned.nodeID == node else {
                mismatches[profile.id] = Mismatch(pinned: pinned, offered: offered)
                throw TrustError.identityChanged(host: profile.id)
            }
            mismatches[profile.id] = nil
            return pinned
        }
        pins[profile.id] = offered
        try save()
        return offered
    }

    /// Fetches and validates the host's identity without pinning, saving or
    /// recording anything. The returned pin is only what the host offered.
    func identify(_ profile: ConnectionProfile) async throws -> Pin {
        let reply = try await request(profile, ["operation": "node_identity"])
        guard reply["authority"] as? String == "relayd" else { throw TrustError.invalidIdentity("not answered by relayd") }
        guard let node = reply["node_id"] as? String, Self.validNodeID(node) else { throw TrustError.invalidIdentity("host ID") }
        guard let pem = reply["certificate_pem"] as? String, let computed = Self.certificateFingerprint(pem),
              reply["certificate_sha256"] as? String == computed else {
            throw TrustError.invalidIdentity("certificate does not match its fingerprint")
        }
        return Pin(hostID: profile.id, nodeID: node, certificatePEM: pem, certificateSHA256: computed, pinnedAt: now())
    }

    /// Owner action: adopt a host's changed key after reviewing it.
    func confirmChangedIdentity(host: UUID) throws {
        guard let mismatch = mismatches[host] else { throw TrustError.unknownHost }
        pins[host] = mismatch.offered
        mismatches[host] = nil
        try save()
    }

    /// The pins a given host should trust: every other pinned host, once per key.
    func trustSet(for target: Pin) -> [[String: Any]] {
        var seen: Set<String> = [target.certificateSHA256]
        return pins.values.sorted { $0.nodeID < $1.nodeID }.compactMap { pin in
            guard pin.nodeID != target.nodeID, seen.insert(pin.certificateSHA256).inserted else { return nil }
            return ["node_id": pin.nodeID, "certificate_pem": pin.certificatePEM,
                    "certificate_sha256": pin.certificateSHA256, "signs_messages": true]
        }
    }

    /// Installs the full trust set on a pinned host.
    func push(to profile: ConnectionProfile) async throws {
        guard let target = pins[profile.id] else { throw TrustError.unknownHost }
        guard mismatches[profile.id] == nil else { throw TrustError.identityChanged(host: profile.id) }
        _ = try await request(profile, ["operation": "node_trust_set", "trusted_nodes": trustSet(for: target)])
    }

    /// Makes `target` trust `source`: pins both (first use only) and pushes.
    func trust(source: ConnectionProfile, onto target: ConnectionProfile) async throws {
        try await observe(source)
        try await observe(target)
        try await push(to: target)
    }

    /// For host attach or upgrade: pin every reachable relay host, then push
    /// the full set to each. Per-host failures are returned, not thrown.
    @discardableResult
    func refresh(profiles: [ConnectionProfile]) async -> [UUID: String] {
        var failures: [UUID: String] = [:]
        var seen: Set<String> = []
        let hosts = profiles.filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
        for profile in hosts {
            do { try await observe(profile) } catch { failures[profile.id] = error.localizedDescription }
        }
        for profile in hosts where failures[profile.id] == nil {
            do { try await push(to: profile) } catch { failures[profile.id] = error.localizedDescription }
        }
        return failures
    }

    private static func daemonRequest(profile: ConnectionProfile, packet: [String: Any]) async throws -> [String: Any] {
        let fallback = RelayHostExecution.daemonCommand(profile: profile, arguments: ["communication"])
        let command = "if [ -x \"$HOME/.local/share/relay/bin/relayd-communication\" ]; then \"$HOME/.local/share/relay/bin/relayd-communication\" communication; else " + fallback + "; fi"
        let result = try await RelayHostExecution.capture(profile: profile, command: command,
            input: JSONSerialization.data(withJSONObject: packet, options: .sortedKeys), timeout: 60, maximumBytes: 128 << 10)
        guard result.exitCode == 0, let value = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw RemoteCatalogError.failed(String(data: result.stderr, encoding: .utf8) ?? "The communication daemon is unavailable")
        }
        return value
    }
}
