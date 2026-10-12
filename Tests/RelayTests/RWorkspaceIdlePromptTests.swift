import Testing
@testable import Relay

@Test func automaticRSetupOnlyUsesAnEmptyRadianPrompt() {
    for text in ["output\n[ins] r$> \n", "r$>", "[nav] r$>"] {
        #expect(RWorkspaceIdlePrompt.accepts(text))
    }
    for text in ["$ ", "> ", "[ins] r$> plot(1)", "[ins] r$>\nrunning…", ":", "+ ", ""] {
        #expect(!RWorkspaceIdlePrompt.accepts(text))
    }
    #expect(!RWorkspaceIdlePrompt.accepts(nil))
}
