import AppKit
import Testing
@testable import Relay

// After launch, agent monitoring marks every pane connected, but a pane's
// terminal starts only when its tab is first laid out. Its prompt has never
// been read, so maintenance must name that, not a missing paste mode.
@MainActor @Test func maintenanceNamesUnopenedTerminalBeforeBracketedPaste() throws {
    _ = NSApplication.shared
    let pane = PaneModel(profile: .local)
    pane.connected()
    #expect(pane.connectionState == .connected)
    #expect(!pane.runtime.agentMaintenanceTerminalPromptIsEmpty)
    #expect(!pane.runtime.agentMaintenancePromptIsEmpty)
    #expect(!pane.runtime.agentMaintenanceTerminalPromptHasTypedText)
    #expect(pane.runtime.agentMaintenanceTerminalPromptBlocker ==
        "the pane's terminal has not been opened since Relay started; select its tab once so its prompt can be read")
}
