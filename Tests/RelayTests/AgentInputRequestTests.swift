import Foundation
import Testing
@testable import Relay

@Test("Agent proposals allow multiline code but reject terminal control injection")
func agentProposalValidation() {
    func valid(_ text: String) -> Bool {
        AgentInputProposal(instance: UUID(), requestID: UUID(), text: text).isValid
    }
    #expect(valid("x <- 1\nprint(x)"))
    #expect(!valid(""))
    #expect(!valid("hello\u{1b}[2J"))
    #expect(!valid("hello\rsubmit"))
    #expect(!valid("hello\0"))
    #expect(!valid(String(repeating: "x", count: 65537)))
}
