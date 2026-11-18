import Foundation

/// Why Relay refused or held a pane operation (close, restart, update,
/// account move, same-pane resume): which fence held, what holds it, and what
/// clears it. The `blocker` is the operation's existing message, so the text an
/// operator already sees is unchanged; the code and the clearing advice are
/// added beside it in MCP results, receipts and the UI.
struct RelayPaneOperationRefusal: Error, Equatable, Sendable, LocalizedError {
    /// Raw values are shared with relayd's PaneRefusal* constants.
    enum Code: String, CaseIterable, Sendable {
        case identityUnavailable = "identity_unavailable"
        case accountMismatch = "account_mismatch"
        case approvalPending = "approval_pending"
        case draftPresent = "draft_present"
        case backgroundWork = "background_work"
        case subagentWork = "subagent_work"
        case promptUnverified = "prompt_unverified"
        case turnActive = "turn_active"
        case transcriptSettling = "transcript_settling"
        case userTyping = "user_typing"
        case resumeUnavailable = "resume_unavailable"
        case manualRestartRequired = "manual_restart_required"
        case loginMismatch = "login_mismatch"
        case targetAccountUnavailable = "target_account_unavailable"
        case relaunchUnavailable = "relaunch_unavailable"
        case outsideProject = "outside_project"
        case launcherUnavailable = "launcher_unavailable"
        case invalidRequest = "invalid_request"
        case paneChanged = "pane_changed"
        case notAuthorized = "not_authorized"
        case paneNotConnected = "pane_not_connected"
        case unsupportedPane = "unsupported_pane"
        case operationInProgress = "operation_in_progress"
        case hostUnreachable = "host_unreachable"
        case exitNotVerified = "exit_not_verified"
        case otherInstall = "other_install"
        case goalActive = "goal_active"
        case notRecoverable = "not_recoverable"
        case unsavedChanges = "unsaved_changes"
        case unclassified

        /// What the operator or an MCP client does to clear this refusal.
        var howToClear: String {
            switch self {
            case .identityUnavailable:
                return "Wait until the pane shows its agent prompt again, then retry with the pane's current session."
            case .accountMismatch:
                return "Move the pane to the account it should use, or record the account the agent runs in; Relay never restarts across accounts."
            case .approvalPending: return "Answer the agent's permission prompt, then retry."
            case .draftPresent: return "Send or clear the unsent prompt, then retry."
            case .backgroundWork:
                return "Wait for the agent's background shells or agent processes to finish, or move with force when the user asks."
            case .subagentWork: return "Wait for the session's subagents to finish, then retry."
            case .promptUnverified:
                return "Let the agent reach an idle, empty prompt; if the pane has not been opened since Relay started, select its tab once."
            case .turnActive: return "Wait for the agent's current turn to finish, then retry."
            case .transcriptSettling: return "Retry in a few seconds, once the conversation transcript stops changing."
            case .userTyping: return "Retry 15 seconds after the last keystroke in the pane."
            case .resumeUnavailable:
                return "Make sure the conversation's transcript exists in the pane's account, or restart the agent by hand."
            case .manualRestartRequired:
                return "This launch uses options Relay does not replay; exit and start the agent by hand in the same pane."
            case .loginMismatch:
                return "Log the account folder in to its pinned ChatGPT account (relayd codex-login), or move the pane to another account."
            case .targetAccountUnavailable:
                return "Turn on shared conversation history for the target account in Settings and sync it, then retry."
            case .relaunchUnavailable:
                return "Nothing was sent. Relaunch the agent by hand in this pane, or restart it through Relay maintenance."
            case .outsideProject: return "Run the resume from a pane whose agent works in the saved conversation's project."
            case .launcherUnavailable:
                return "Repair Relay's agent launchers on that host (relayd agent-launchers --repair), then retry."
            case .invalidRequest: return "Pass the exact pane, session and request UUIDs."
            case .paneChanged: return "Read the pane again and retry with its current state and a fresh request ID."
            case .notAuthorized: return "Grant the capability the operation needs in Relay, then retry with a fresh request ID."
            case .paneNotConnected: return "Reconnect the pane (relay_recover_pane), then retry."
            case .unsupportedPane:
                return "Only Claude and Codex panes on a Relay-managed backend support this; use the pane's own exit and relaunch."
            case .operationInProgress: return "Wait for the running maintenance, move or resume on this pane to finish."
            case .hostUnreachable: return "Check the host's connection and relayd, then retry with a fresh request ID."
            case .exitNotVerified:
                return "The agent was asked to exit but its retained shell was not proven ready; inspect the pane, then resume it again with the same session (Relay relaunches into the proven retained shell)."
            case .otherInstall:
                return "The newer agent is a different install; restart the pane by hand onto that install."
            case .goalActive:
                return "The Codex /goal is still pursuing its objective; wait for it, or pause or clear it with /goal, then retry."
            case .notRecoverable: return "List the host's managed panes again; the pane is gone or no longer running."
            case .unsavedChanges: return "Save or discard the pane's unsaved editor changes, then close it."
            case .unclassified: return "Read the blocker text; it names what held the operation."
            }
        }
    }

    let code: Code
    let blocker: String
    let howToClear: String

    init(_ code: Code, _ blocker: String, howToClear: String? = nil) {
        self.code = code
        self.blocker = blocker
        self.howToClear = howToClear ?? code.howToClear
    }

    var errorDescription: String? { blocker }

    /// The blocker followed by its clearing advice, for a status line.
    var displayText: String { blocker + " To clear: " + howToClear }

    /// Flat receipt and MCP fields.
    var fields: [String: String] {
        ["reason_code": code.rawValue, "blocker": blocker, "how_to_clear": howToClear]
    }

    /// The code for an existing refusal text that carries none (an older
    /// relayd's resume_error, or a refusal site with no code of its own).
    /// First match wins; anything else is unclassified.
    static func classify(_ message: String) -> Code {
        let table: [(String, Code)] = [
            ("needs a manual restart", .manualRestartRequired),
            ("ChatGPT", .loginMismatch), ("logged in", .loginMismatch),
            ("not visible from the target account", .targetAccountUnavailable),
            ("target account could not bind", .targetAccountUnavailable),
            ("already uses that account", .targetAccountUnavailable),
            ("is not ready for this conversation", .targetAccountUnavailable),
            (RelayAgentMaintenancePrompt.goalBlockerPrefix, .goalActive),
            ("terminal input grant", .notAuthorized), ("user-initiated only", .notAuthorized),
            ("Only the user can", .notAuthorized), ("No durable quota failover intent", .notAuthorized),
            ("Maintenance or another move", .operationInProgress), ("another input operation", .operationInProgress),
            ("not connected", .paneNotConnected), ("disconnected", .paneNotConnected),
            ("permission prompt", .approvalPending), ("pending approval", .approvalPending),
            ("unsent prompt", .draftPresent), ("draft", .draftPresent),
            ("could not read its screen", .promptUnverified), ("read this pane's screen", .promptUnverified),
            ("confirmed empty", .promptUnverified), ("overlay", .promptUnverified),
            ("prompt delivery", .operationInProgress),
            ("did not stop", .turnActive), ("current turn", .turnActive),
            ("background", .backgroundWork), ("subagent", .subagentWork),
            ("native identity", .identityUnavailable), ("native state", .identityUnavailable),
            ("cannot be moved", .unsupportedPane), ("does not run a Claude or Codex agent", .unsupportedPane),
            ("changed", .paneChanged),
            ("resume command is unavailable", .resumeUnavailable), ("move command is unavailable", .resumeUnavailable),
            ("cannot prepare an account move", .resumeUnavailable),
            ("could not be reached", .hostUnreachable), ("relayd could not", .hostUnreachable),
        ]
        return table.first { message.localizedCaseInsensitiveContains($0.0) }?.1 ?? .unclassified
    }

    /// relayd's structured refusal line ("refusal: {json}") from a refusing
    /// command's stderr, or nil when that relayd predates it.
    static func hostRefusal(stderr: Data) -> RelayPaneOperationRefusal? {
        struct Line: Decodable {
            let reasonCode: String
            let blocker: String
            let howToClear: String
            enum CodingKeys: String, CodingKey {
                case reasonCode = "reason_code", blocker, howToClear = "how_to_clear"
            }
        }
        let text = String(decoding: stderr.prefix(4096), as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("refusal: ") {
            guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.dropFirst("refusal: ".count).utf8))
            else { continue }
            let code = Code(rawValue: decoded.reasonCode) ?? .unclassified
            return .init(code, decoded.blocker, howToClear: code == .unclassified ? nil : decoded.howToClear)
        }
        return nil
    }

    /// The blocker line of a refusing relayd command: its first line without
    /// the "relayd: " prefix.
    static func hostBlocker(stderr: Data) -> String {
        let text = String(decoding: stderr.prefix(500), as: UTF8.self)
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.hasPrefix("relayd: ") ? String(first.dropFirst("relayd: ".count)) : first
    }
}
