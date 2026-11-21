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

@MainActor @Test func nativeInlineMarkdownLinksBareURLsImagesAndStylesCode() {
    let text = RelayAgentMarkdownText.inlineAttributed("See https://example.com/a_b. and `https://code.example` ![fig](https://x.org/q.png) *it* ~~gone~~")
    let plain = String(text.characters)
    #expect(plain.contains("🖼 fig"))
    #expect(!plain.contains("!["))
    let links = text.runs.compactMap(\.link).map(\.absoluteString)
    #expect(links.contains("https://example.com/a_b"))
    #expect(links.contains("https://x.org/q.png"))
    #expect(!links.contains("https://code.example"))
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.backgroundColor != nil })
}

@Test func terminalFooterCopiesStatusRowsUnderTheInputBox() {
    let claude = ["⏺ Done.", "", "────────────", "❯ draft text", "  wraps here", "────────────",
                  "  Opus 5.5 · ctx 41% · $0.94", "  ⏵⏵ bypass permissions on (shift+tab to cycle)", ""]
    #expect(RelayAgentTerminalFooter.rows(provider: "claude", screen: claude) ==
            ["Opus 5.5 · ctx 41% · $0.94", "⏵⏵ bypass permissions on (shift+tab to cycle)"])
    let codex = ["• Ran tests", "", "› Ask Codex to do anything", "", "  gpt-5.5 high · 62% left · ~/dev/term"]
    #expect(RelayAgentTerminalFooter.rows(provider: "codex", screen: codex) == ["gpt-5.5 high · 62% left · ~/dev/term"])
    #expect(RelayAgentTerminalFooter.rows(provider: "claude", screen: ["no prompt here"]).isEmpty)
    #expect(RelayAgentTerminalFooter.rows(provider: "shell", screen: claude).isEmpty)
}

@Test func inlineImagesSplitOutsideFencesOnly() {
    let source = "Intro\n\n![fig](/tmp/a.png)\n\n```md\n![no](/tmp/b.png)\n```\n- ![](rel/c.svg)\nSee ![web](https://x.org/d.png) end"
    #expect(RelayAgentInlineImages.segments(source) == [
        .text("Intro\n"), .image(path: "/tmp/a.png", alt: "fig"),
        .text("\n```md\n![no](/tmp/b.png)\n```"), .image(path: "rel/c.svg", alt: ""),
        .text("See ![web](https://x.org/d.png) end")])
    #expect(RelayAgentInlineImages.segments("plain") == [.text("plain")])
}
