import Foundation
import Testing
@testable import Relay

@Test func nativeConversationPreservesSourceBlocksAndPartialStream() {
    #expect(RelayAgentMarkdownBlocks.split("Hello\n```mermaid\ngraph LR\nA-->B\n```\n$$\nx^2\n$$") == [
        .markdown("Hello"), .diagram("graph LR\nA-->B"), .equation("x^2")])
    #expect(RelayAgentMarkdownBlocks.split("```text\n$$\nx\n$$\n```") == [.code(language: "text", source: "$$\nx\n$$")])
    #expect(RelayAgentMarkdownBlocks.split("Hello\n```mermaid\ngraph LR") == [.markdown("Hello\n```mermaid\ngraph LR")])
    #expect(RelayAgentMarkdownBlocks.split("\\[\nx^2\n\\]") == [.equation("x^2")])
}

@Test func nativeConversationExactBindingAndRevisionGate() {
    let pane = UUID()
    let binding = RelayAgentConversationBinding(hostID: "local", paneID: pane, provider: "claude",
        processID: 123, processStart: "start-one", sessionID: "exact")
    let reused = RelayAgentConversationBinding(hostID: "local", paneID: pane, provider: "claude",
        processID: 123, processStart: "start-two", sessionID: "exact")
    var conversation = RelayAgentConversation()
    conversation.bind(binding)
    let first = RelayAgentConversationItem(id: "message", turnID: nil, role: .assistant,
        blocks: [.markdown("partial")], revision: 1, complete: false)
    let rejectedBinding = conversation.receive(first, binding: reused)
    let acceptedFirst = conversation.receive(first, binding: binding)
    let rejectedDuplicate = conversation.receive(first, binding: binding)
    #expect(!rejectedBinding)
    #expect(acceptedFirst)
    #expect(!rejectedDuplicate)
    let completed = RelayAgentConversationItem(id: "message", turnID: nil, role: .assistant,
        blocks: [.markdown("complete")], revision: 2, complete: true)
    let acceptedCompleted = conversation.receive(completed, binding: binding)
    #expect(acceptedCompleted)
    #expect(conversation.items == [completed])
    conversation.bind(reused)
    #expect(conversation.items.isEmpty)
    let rejectedOldProcess = conversation.receive(completed, binding: binding)
    #expect(!rejectedOldProcess)
}

@Test func configuredRemoteAgentReturnsToShell() {
    var profile = ConnectionProfile(host: "fixture")
    profile.kind = .ssh
    profile.backend = .direct
    profile.command = "exec codex resume --last"
    let command = profile.remoteCommand(forPane: UUID())
    #expect(command?.hasPrefix("exec /bin/sh -c ") == true)
    #expect(command?.contains("-il") == true)
    profile.command = ""
    #expect(profile.remoteCommand(forPane: UUID()) == nil)
}
