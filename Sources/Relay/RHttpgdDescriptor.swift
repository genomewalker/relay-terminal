import Foundation

/// The companion's httpgd endpoint record (`httpgd.json`). It is untrusted
/// input read from the remote artifact root: every field is bounded, the
/// endpoint must be the R host's own loopback address, and it must belong to
/// the currently validated R session. Relay never connects to the host named
/// here directly; remote profiles use the Relay-native loopback bridge.
struct RHttpgdDescriptor: Decodable, Sendable, Equatable {
    let version: Int
    let session_id: String
    let pid: Int
    let host: String
    let port: Int
    let token: String
    let device: Int
    let artifact_root: String
    let httpgd_version: String?
    let started_at: String?

    static let tokenPattern = "^[0-9a-f]{64}$"

    /// Rejects foreign hosts, malformed tokens, and descriptors written by a
    /// different R process or artifact root than the reviewed session.
    func validate(session: RWorkspaceSession, root: String) throws {
        guard version == 1 else { throw PluginError.invalid("Unsupported httpgd descriptor version; update the R companion") }
        guard host == "127.0.0.1" else { throw PluginError.invalid("httpgd must listen on the R host's loopback address only") }
        guard (1...65535).contains(port) else { throw PluginError.invalid("Invalid httpgd port") }
        guard token.range(of: Self.tokenPattern, options: .regularExpression) != nil else {
            throw PluginError.invalid("httpgd descriptor lacks a Relay-generated token")
        }
        guard device >= 2, device <= 1024 else { throw PluginError.invalid("Invalid httpgd device number") }
        guard session_id == session.session_id, pid == session.pid, artifact_root == session.artifact_root,
              artifact_root == root else {
            throw PluginError.invalid("httpgd descriptor belongs to another R session. Start httpgd again from the connected console.")
        }
        guard (httpgd_version ?? "").utf8.count <= 64, (started_at ?? "").utf8.count <= 64 else {
            throw PluginError.invalid("Oversized httpgd descriptor")
        }
    }

    static func decode(_ bytes: Data) throws -> RHttpgdDescriptor {
        guard bytes.count <= 8 * 1024 else { throw PluginError.invalid("Oversized httpgd descriptor") }
        return try JSONDecoder().decode(RHttpgdDescriptor.self, from: bytes)
    }
}

// The token is a bearer credential: string conversion, debugging and
// reflection deliberately omit it so it cannot reach logs or status text.
extension RHttpgdDescriptor: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "httpgd device \(device) on 127.0.0.1:\(port) for R PID \(pid) (token redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["session_id": session_id, "pid": pid, "port": port, "device": device, "token": "<redacted>"])
    }
}
