import Foundation
import Testing
@testable import Relay

@Suite struct RelayClaudePromptAttestorTests {
    @Test func acceptsOnlyStableLastLineWithExactNbspPromptAndNoTypedInput() {
        let ready = "recent output\n❯\u{00A0}\n"
        #expect(RelayClaudePromptAttestor.isEmptyReadyPrompt(ready))
        #expect(RelayClaudePromptAttestor.stable(ready, ready))
        #expect(!RelayClaudePromptAttestor.isEmptyReadyPrompt("recent output\n❯ hello\n"))
        #expect(!RelayClaudePromptAttestor.isEmptyReadyPrompt("recent output\n❯\u{00A0}typed\n"))
        #expect(!RelayClaudePromptAttestor.isEmptyReadyPrompt("recent output\n❯ \n"))
        #expect(!RelayClaudePromptAttestor.isEmptyReadyPrompt("recent output\n❯\u{00A0}\n1. Allow\n"))
        #expect(!RelayClaudePromptAttestor.stable(ready, "changed output\n❯\u{00A0}\n"))
        #expect(!RelayClaudePromptAttestor.isEmptyReadyPrompt(String(repeating: "x", count: 32_768)))
    }
}
