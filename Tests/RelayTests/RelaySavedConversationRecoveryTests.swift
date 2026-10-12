import Foundation
import Testing
@testable import Relay

@Test("Saved conversation commands retain exact session and binding identities")
func savedConversationCommandIdentity() throws {
    let pane = "70665c50-9cca-441d-a03c-1f11aff57d32"
    let session = "c500790e-1e1a-4d15-a613-df83c1bdca1d"
    let sha = String(repeating: "a", count: 64)
    let plan = RelaySavedConversationPlan(paneID: pane, provider: "claude", sessionID: session,
                                         directory: "/tmp/a directory", bindingSHA: sha)
    let command = try plan.command(profile: .local)
    #expect(command.contains("'resume-saved' '\(pane)' '\(session)' '\(sha)'"))
    #expect(!command.contains("/tmp/a directory"))
    let bad = RelaySavedConversationPlan(paneID: pane, provider: "claude", sessionID: "x;echo wrong",
                                        directory: "/tmp", bindingSHA: sha)
    #expect(throws: RemoteCatalogError.self) { try bad.command(profile: .local) }
}
