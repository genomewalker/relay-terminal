import Foundation

/// Why a pane's context management is or is not running: handoff text
/// (API key), enrollment, and whether the host observes completed turns.
/// A pure function of the host replies, so the panel only renders it.
struct RelayContextManagementSummary: Equatable, Sendable {
    enum Check: Equatable, Sendable {
        case ok(String)
        case attention(String)
        case unknown(String)

        var text: String {
            switch self { case .ok(let s), .attention(let s), .unknown(let s): s }
        }
        var isOK: Bool { if case .ok = self { true } else { false } }
        var isUnknown: Bool { if case .unknown = self { true } else { false } }
    }

    let handoffText: Check
    let enrollment: Check
    let completedTurns: Check
    /// The first unmet requirement, phrased as what to do about it.
    let nextStep: String?

    var line: String { [handoffText, enrollment, completedTurns].map(\.text).joined(separator: " · ") }

    init(rotation: RelayHostRotationRPC.Status?, text: RelayHostRotationTextRPC.Status?,
         credentials: [RelayHostRotationTextRPC.CredentialRecord]?, now: Date = Date()) {
        handoffText = Self.handoffText(text: text, credentials: credentials)
        enrollment = Self.enrollment(rotation)
        completedTurns = Self.completedTurns(rotation, now: now)

        if case .attention = handoffText {
            nextStep = "Set up handoff text in Settings → Accounts before enabling context management."
        } else if case .attention = enrollment {
            nextStep = "Press Enable to let the host manage this session's context."
        } else if case .attention = completedTurns {
            nextStep = "The host has not reported a completed turn for this pane yet, so no rotation can be evaluated."
        } else {
            nextStep = nil
        }
    }

    private static func handoffText(text: RelayHostRotationTextRPC.Status?,
                                     credentials: [RelayHostRotationTextRPC.CredentialRecord]?) -> Check {
        guard let text else { return .unknown("Handoff text status unavailable") }
        if text.isUnsupported { return .attention("Host update required for handoff text") }
        guard !text.isNotConfigured, let settings = text.settings else { return .attention("Handoff text not set up") }
        guard settings.enabled else { return .attention("Handoff text off") }
        let usable = (settings.accounts ?? []).filter { $0.enabled && settings.providers.contains($0.provider) }
        guard !usable.isEmpty else { return .attention("No enabled handoff account") }
        // Account logins (Claude Code / Codex) keep their credentials inside the CLI.
        if usable.contains(where: { $0.provider != "anthropic_api" }) { return .ok("Handoff account OK") }
        guard let credentials else { return .unknown("API key status unavailable") }
        let saved = Set(credentials.filter { $0.state == "saved" }.map(\.reference))
        if usable.contains(where: { $0.credentialReference.map(saved.contains) == true }) { return .ok("API key OK") }
        let states = usable.compactMap { account in
            credentials.first(where: { $0.reference == account.credentialReference })?.stateLabel
        }
        return .attention(states.first.map { "API key: \($0)" } ?? "API key not saved")
    }

    private static func enrollment(_ rotation: RelayHostRotationRPC.Status?) -> Check {
        guard let rotation else { return .unknown("Enrollment unknown") }
        if rotation.isUnsupported { return .attention("Host update required") }
        if rotation.enabled == true { return .ok("Pane enrolled") }
        if rotation.state == "human_takeover" { return .attention("Paused after your input") }
        return .attention("Pane not enrolled")
    }

    private static func completedTurns(_ rotation: RelayHostRotationRPC.Status?, now: Date) -> Check {
        guard let rotation, !rotation.isUnsupported else { return .unknown("Completed turns unknown") }
        guard let count = rotation.observedCompletedTurns else {
            return .unknown("Completed turns not reported by this host")
        }
        guard count > 0 else { return .attention("No completed turns observed") }
        let noun = count == 1 ? "completed turn" : "completed turns"
        var text = "\(count) \(noun) observed"
        if let at = rotation.lastCompletedTurnAt.flatMap(parseTimestamp) {
            text += ", last \(RelativeDateTimeFormatter().localizedString(for: at, relativeTo: now))"
        }
        return .ok(text)
    }

    /// Go encodes RFC 3339 with up to nine fractional digits; Foundation
    /// parses at most milliseconds, so the fraction is trimmed first.
    static func parseTimestamp(_ value: String) -> Date? {
        var text = value
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            text = String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                + String(text[end...])
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
