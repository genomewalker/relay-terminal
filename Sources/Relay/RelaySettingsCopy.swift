import Foundation

/// User-facing Settings text. Labels describe what the user gets; internal names
/// (relayd, supervisors, sockets, receipts) appear only in the `…Detail` tooltips.
enum RelaySettingsCopy {
    // The assistant entry point appears once, in the Settings sidebar, not on every page.
    static let askMiko = "Ask Miko…"
    static let askMikoDetail = "Miko can explain a setting and propose a change on this Mac. You review the change before it is applied; Relay records a verified settings receipt."

    /// One-line page description under the page title. Page headers carry no Miko text.
    static func description(section: String) -> String {
        switch section {
        case "keyboard": "Customize shortcuts for sessions, tabs and panes."
        case "accounts": "API keys Relay itself uses on each host (handoff text), shared by every tab. Agent sign-ins are under Agent Accounts."
        case "agent-accounts": "Work and personal Claude and Codex accounts on each host."
        case "intelligence": "Optional features that use models on this Mac."
        case "connections": connectionsDescription
        case "clients": "Control which clients can work with Relay."
        case "plugins": "Manage extensions for your workspace."
        case "advanced": "Terminal compatibility and diagnostics."
        default: "Choose how your terminal and workspace look."
        }
    }

    static let connectionsDescription = "Remote helper and sessions on your SSH hosts."
    static let connectionsSection = "Remote sessions"
    static let autoUpdateHelper = "Keep the remote helper up to date on approved hosts"
    static let autoUpdateHelperDetail = "Updates relayd, Relay's helper process on each SSH host."
    static let checkHelpers = "Check remote helpers and sessions"
    static let connectionsExplanation = "Relay installs a small helper on each host you connect to and asks before the first install. Hosts that share a home folder share one copy. Approved hosts can update it automatically."
    static let connectionsExplanationDetail = "The helper is relayd. Nodes in a shared home reuse one verified binary; each node runs its own supervisor and socket."

    static let helperManagerSubtitle = "Relay runs a small helper on each remote host to keep sessions alive."
    static let helperManagerSubtitleDetail = "The helper is relayd. Hosts that share a home folder share one installed copy, and each host runs its own relayd supervisor."

    static let agentHelperUpdates = "Let agent panes ask Miko to update the remote helper on hosts"
    static let agentHelperUpdatesExplanation = "When on, a coding agent's request to Miko to update the remote helper on a configured host carries your authority and runs without a card. Every other agent request still waits for your Run. Only you can change this here."
    static let agentHelperUpdatesDetail = "The remote helper is relayd."

    static let palette = "Terminal palette"
    static let paletteExplanation = "Terminal palettes are dark. The rest of Relay follows your Mac's Light or Dark appearance."

    static let decisionModelExplanation = "This optional model uses numeric session measurements to suggest when a session needs attention. Apple’s model does not require an additional file."

    /// Every label above that is shown as visible text (tooltips excluded).
    static let visibleLabels = [
        askMiko, connectionsDescription, connectionsSection, autoUpdateHelper, checkHelpers,
        connectionsExplanation, helperManagerSubtitle, agentHelperUpdates,
        agentHelperUpdatesExplanation, palette, paletteExplanation, decisionModelExplanation,
    ]
}
