import Foundation
import Testing
@testable import Relay

@Test("Nested splits preserve pane ordering")
func nestedSplits() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let layout = PaneLayout.pane(a)
        .splitting(a, axis: .horizontal, with: b)
        .splitting(b, axis: .vertical, with: c)

    #expect(layout.paneIDs == [a, b, c])
}

@Test("Removing a pane collapses its empty split")
func splitRemoval() {
    let a = UUID()
    let b = UUID()
    let layout = PaneLayout.pane(a).splitting(a, axis: .horizontal, with: b)

    #expect(layout.removing(a) == .pane(b))
}

@Test("Tiled panes can swap positions without changing identity")
func splitSwap() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let layout = PaneLayout.pane(a)
        .splitting(a, axis: .horizontal, with: b)
        .splitting(b, axis: .vertical, with: c)

    #expect(layout.swapping(a, c).paneIDs == [c, b, a])
}

@Test("Image paths are detected once in agent output")
func imagePathDetection() {
    var detector = ImagePathDetector()
    let codex = "Saved to file:///home/test/.codex/generated_images/demo/image.png\r\n"
    #expect(detector.ingest(codex) == ["/home/test/.codex/generated_images/demo/image.png"])
    #expect(detector.ingest("Displayed /home/test/.codex/generated_images/demo/image.png") == [])
    #expect(detector.ingest("not an image: /home/test/notes.txt") == [])
}

@Test("Kitty image transport is chunked and terminated")
func kittyImagePackets() {
    let image = Data(repeating: 0xAB, count: 5_000)
    let packets = KittyImageEncoder.packets(for: image, imageID: 42, columns: 36)
    let text = packets.compactMap { String(data: $0, encoding: .utf8) }.joined()

    #expect(packets.count > 3)
    #expect(text.contains("a=T,f=100,q=2,i=42,c=36,m=1"))
    #expect(text.contains("q=2,i=42,m=0"))
    #expect(text.hasSuffix("\r\n"))
}

@MainActor
@Test("A tab tracks tiled and floating panes together")
func tabIncludesFloatingPanes() {
    let tiled = UUID()
    let floating = UUID()
    let tab = TabModel(
        name: "HPC",
        firstPane: tiled,
        floatingPanes: [.initial(paneID: floating, index: 0)]
    )

    #expect(tab.allPaneIDs == [tiled, floating])
}

@MainActor
@Test("Full screen hides and restores the session navigator")
func fullScreenChrome() {
    let workspace = WorkspaceModel()
    workspace.sidebarVisible = true

    workspace.setFullScreen(true)
    #expect(workspace.isFullScreen)
    #expect(!workspace.sidebarVisible)

    workspace.setFullScreen(false)
    #expect(!workspace.isFullScreen)
    #expect(workspace.sidebarVisible)
}

@Test("Agent detector recognizes Claude and approval prompts")
func claudeAttentionSignal() {
    var detector = AgentSignalDetector()
    detector.ingest("Claude Code\nThis action requires approval. Do you want to proceed? (y/n)")

    #expect(detector.kind == .claude)
    #expect(detector.phase == .needsInput)

    detector.acknowledgeInput()
    #expect(detector.phase == .active)
}

@Test("Agent detector recognizes Codex")
func codexSignal() {
    var detector = AgentSignalDetector()
    detector.ingest("OpenAI Codex CLI\nWorking on your repository")

    #expect(detector.kind == .codex)
    #expect(detector.phase == .active)
}

@Test("SSH config discovery keeps aliases and rejects patterns")
func sshConfigAliases() {
    let config = """
    Host hpc-login gpu-02 *.cluster !blocked
      HostName dandy.example.edu
    Host "quoted-host" # comment
    Match host anything
      User ignored
    """

    #expect(SSHConfigDiscovery.literalHosts(in: config) == ["hpc-login", "gpu-02", "quoted-host"])
}

@Test("SSH config aliases defer connection options to OpenSSH")
func sshConfigConnectionArguments() {
    let profile = ConnectionProfile.sshConfigHost("hpc-login")
    #expect(profile.sshConnectionArguments == ["hpc-login"])
    #expect(profile.backend == .relay)
}

@Test("Host search tolerates omitted characters")
func fuzzyHostSearch() {
    #expect(HostSearch.score(query: "hpc", candidate: "hpc-login SSH config") != nil)
    #expect(HostSearch.score(query: "gpu7", candidate: "gpu-login-07") != nil)
    #expect(HostSearch.score(query: "ocean", candidate: "hpc-login SSH config") == nil)
}

@MainActor
@Test("Structured Codex events override terminal heuristics")
func structuredCodexEvent() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    let event = """
    {"agent":"codex","event":{"hook_event_name":"SessionStart","source":"process-tree"}}
    """
    pane.receivedAgentEvent(Data(event.utf8))
    #expect(pane.kind == .codex)
    #expect(pane.phase == .active)
}

@MainActor
@Test("Structured subagent events retain identity and lifecycle")
func structuredSubagentLifecycle() {
    let pane = PaneModel(profile: .sshConfigHost("hpc-login"))
    pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStart","agent_id":"research-1","agent_type":"Explore"}}"#.utf8))
    #expect(pane.activeSubagents == 1)
    #expect(pane.subagents.first?.id == "research-1")
    #expect(pane.subagents.first?.label == "Explore")

    pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"SubagentStop","agent_id":"research-1"}}"#.utf8))
    #expect(pane.activeSubagents == 0)
    #expect(pane.subagents.isEmpty)
}
