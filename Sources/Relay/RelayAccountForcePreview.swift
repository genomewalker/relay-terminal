import Foundation

/// The explicit selection made before a host preview. It is checked again
/// against the host response; a returned response cannot redirect the card.
struct RelayAccountForceSelection: Equatable, Sendable {
    let paneID: UUID
    let provider: String
    let sessionID: String
    let providerPID: Int
    let providerStart: String
    let blockerPID: Int
    let blockerStart: String

    /// Empty blockerStart asks the host to resolve the selected PID to its
    /// full kernel start; the returned value must be shown before any commit.
    var previewRequest: [String: Any]? {
        guard ["claude", "codex"].contains(provider), !sessionID.isEmpty, sessionID.utf8.count <= 256,
              providerPID > 1, blockerPID > 1, providerPID != blockerPID,
              UInt64(providerStart).map({ $0 > 0 }) == true,
              blockerStart.isEmpty || UInt64(blockerStart).map({ $0 > 0 }) == true else { return nil }
        return ["operation": "account_force_preview", "account_force": ["target": [
            "pane": paneID.uuidString.lowercased(), "provider": provider, "session": sessionID,
            "provider_pid": providerPID, "provider_start": providerStart,
            "blocker_pid": blockerPID, "blocker_start": blockerStart
        ]]]
    }
}

/// Immutable selection whose displayed command is bound to one host preview.
/// This value is presentation data; it does not itself authorize a signal.
struct RelayAccountForcePreview: Equatable, Sendable {
    let host: String
    let paneID: UUID
    let provider: String
    let sessionID: String
    let providerPID: Int
    let providerStart: String
    let blockerPID: Int
    let blockerStart: String
    let commandDigest: String
    let arguments: [String]

    private struct HostTarget: Decodable {
        let pane, provider, session, provider_start, blocker_start, command_digest: String
        let provider_pid, blocker_pid: Int
    }
    private struct HostResult: Decodable {
        let status: String
        let target: HostTarget
        let argv: [String]
    }

    /// Decode only a successful host preview for the exact selection. The
    /// host is supplied by the captured app context, not the response body.
    static func fromHostResult(_ data: Data, host: String, selection: RelayAccountForceSelection) -> Self? {
        guard data.count <= 100_000,
              let result = try? JSONDecoder().decode(HostResult.self, from: data), result.status == "ready",
              UUID(uuidString: result.target.pane) == selection.paneID,
              result.target.provider == selection.provider, result.target.session == selection.sessionID,
              result.target.provider_pid == selection.providerPID, result.target.provider_start == selection.providerStart,
              result.target.blocker_pid == selection.blockerPID,
              (selection.blockerStart.isEmpty || result.target.blocker_start == selection.blockerStart) else { return nil }
        let value = Self(host: host, paneID: selection.paneID, provider: selection.provider, sessionID: selection.sessionID,
                         providerPID: selection.providerPID, providerStart: selection.providerStart,
                         blockerPID: selection.blockerPID, blockerStart: result.target.blocker_start,
                         commandDigest: result.target.command_digest, arguments: result.argv)
        return value.isValid ? value : nil
    }

    var isValid: Bool {
        guard !host.isEmpty, host.utf8.count <= 1024,
              ["claude", "codex"].contains(provider),
              !sessionID.isEmpty, sessionID.utf8.count <= 256,
              providerPID > 1, blockerPID > 1, providerPID != blockerPID,
              UInt64(providerStart).map({ $0 > 0 }) == true, UInt64(blockerStart).map({ $0 > 0 }) == true,
              commandDigest.utf8.count == 64,
              commandDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !arguments.isEmpty, arguments.count <= 128 else { return false }
        return arguments.reduce(0) { $0 + $1.utf8.count } <= 16_384 &&
            arguments.allSatisfy { !$0.unicodeScalars.contains(where: { $0.value == 0 }) }
    }

    /// Preserve argument boundaries; escape controls and directional marks so
    /// displayed text cannot conceal or visually reorder the reviewed bytes.
    static func quoted(_ value: String) -> String {
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x22: return "\\\""
            case 0x5c: return "\\\\"
            default:
                // Render non-ASCII scalars explicitly too: combining marks
                // and confusable characters must not hide reviewed bytes.
                if scalar.value > 0x7e { return String(format: "\\u{%04X}", scalar.value) }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return String(format: "\\u{%04X}", scalar.value)
                default: return String(scalar)
                }
            }
        }.joined()
        return "\"" + escaped + "\""
    }

    var displayedCommand: String? {
        guard isValid else { return nil }
        return arguments.map(Self.quoted).joined(separator: " ")
    }

    /// Construct the mutation from the immutable, displayed preview. The
    /// action ID belongs to this card and must be retained on uncertainty.
    func commitRequest(actionID: UUID) -> [String: Any]? {
        guard isValid else { return nil }
        return ["operation": "account_force_commit", "account_force": [
            "action_id": actionID.uuidString.lowercased(), "target": [
                "pane": paneID.uuidString.lowercased(), "provider": provider, "session": sessionID,
                "provider_pid": providerPID, "provider_start": providerStart,
                "blocker_pid": blockerPID, "blocker_start": blockerStart, "command_digest": commandDigest
            ], "reviewed_argv": arguments
        ]]
    }
}
