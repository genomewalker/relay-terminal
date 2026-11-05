import Foundation
import Testing
@testable import GhosttyTerminal
@testable import Relay

@Test("Native viewport projection drops logical scrollback without losing input styling")
func terminalScreenViewportProjectsLongStyledRow() throws {
    let visible = "❯ \n────────────────\n  term:main | [Opus 5.5]\n  ⏵⏵ bypass permissions on"
    let raw = "\u{1b}]10;rgb:aa/aa/aa\u{1b}\\\u{1b}[90m" + String(repeating: "history", count: 45000) +
        "\u{1b}[0m\r\n" + visible.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(raw.utf8.count > 256 << 10)
    let projected = try #require(TerminalScreenViewportProjection.project(raw, viewport: visible))
    #expect(projected.utf8.count < 1000)
    #expect(RelayAgentMaintenancePrompt.isEmpty(projected, provider: "claude"))
    #expect(!RelayAgentMaintenancePrompt.hasTypedText(projected, provider: "claude"))
}

@Test("Projection retains typed text and native faint placeholders")
func terminalScreenViewportRetainsTypedAndFaintState() throws {
    let visible = "❯ text\n────────────────\n  term:main | [Opus 5.5]\n  ⏵⏵ bypass permissions on"
    let typed = try #require(TerminalScreenViewportProjection.project("\u{1b}[90mhistory\u{1b}[0m\n" + visible, viewport: visible))
    #expect(RelayAgentMaintenancePrompt.hasTypedText(typed, provider: "claude"))
    #expect(!RelayAgentMaintenancePrompt.isEmpty(typed, provider: "claude"))
    let faint = try #require(TerminalScreenViewportProjection.project("\u{1b}[90mhistory\n" + visible, viewport: visible))
    #expect(!RelayAgentMaintenancePrompt.hasTypedText(faint, provider: "claude"))
}

@Test("A mismatched, malformed, oversized or cursor-edited export grants no viewport proof")
func terminalScreenViewportRejectsUnprovenExport() {
    #expect(TerminalScreenViewportProjection.project("actual", viewport: "different") == nil)
    #expect(TerminalScreenViewportProjection.project("\u{1b}[2Jtext", viewport: "text") == nil)
    #expect(TerminalScreenViewportProjection.project("\u{1b}[31", viewport: "text") == nil)
    #expect(TerminalScreenViewportProjection.project("old\rtext", viewport: "text") == nil)
    #expect(TerminalScreenViewportProjection.project(String(repeating: "x", count: (1 << 20) + 1), viewport: "x") == nil)
    #expect(!RelayAgentMaintenancePrompt.isEmpty(String(repeating: "x", count: (1 << 20) + 1), provider: "claude"))
}
