import Foundation
import Testing
@testable import Relay

@Suite("Native chat legibility") struct RelayNativeChatLegibilityTests {
    @Test func longOutputCollapsesToTwelveLinesAndExpands() {
        let text = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let presentation = RelayToolPresentation(tool: "Bash", text: text)
        #expect(presentation.collapsible)
        #expect(presentation.visibleLines(expanded: false).count == 12)
        #expect(presentation.hiddenLineCount == 48)
        #expect(RelayToolPresentation.expandLabel(hidden: presentation.hiddenLineCount) == "Show 48 more lines")
        #expect(presentation.visibleLines(expanded: true).count == 60)
        #expect(presentation.visibleText(expanded: true) == text)
        let short = RelayToolPresentation(tool: "Bash", text: (1...12).map(String.init).joined(separator: "\n"))
        #expect(!short.collapsible && short.visibleLines(expanded: false).count == 12)
    }

    @Test func tabsExpandToAlignedColumns() {
        #expect(RelayToolPresentation.expandTabs("damage_5p=0.012\tmapq30=120731") == "damage_5p=0.012 mapq30=120731")
        // Each tab-separated field starts on a tab stop, as in a terminal, so columns line up.
        for raw in ["sample\tdamage_5p\tmapq30", "S01\t0.012\t120731", "S100\t0.0072\t9"] {
            let fields = raw.split(separator: "\t").map(String.init)
            let row = RelayToolPresentation.expandTabs(raw)
            var column = 0
            for (index, field) in fields.enumerated() {
                if index > 0 { column = (column / 8 + 1) * 8 }
                #expect(column % RelayToolPresentation.tabWidth == 0)
                #expect(String(Array(row)[column..<column + field.count]) == field)
                column += field.count
            }
        }
        #expect(!RelayToolPresentation(tool: "Bash", text: "a\tb").lines[0].text.contains("\t"))
    }

    @Test func diffLinesAreClassifiedOnlyForDiffShapedContent() {
        let diff = "--- a/x.json\n+++ b/x.json\n@@ -1,2 +1,2 @@\n-old\n+new\n same"
        let presentation = RelayToolPresentation(tool: "Bash", text: diff)
        #expect(presentation.isDiff)
        #expect(presentation.lines.map(\.kind) == [.header, .header, .hunk, .removed, .added, .plain])
        #expect(RelayToolOutputView.role(.removed) == .danger && RelayToolOutputView.role(.added) == .success)
        #expect(RelayToolOutputView.role(.plain) == nil)
        // An ordinary list or flag output is not a diff.
        let list = RelayToolPresentation(tool: "Bash", text: "- first item\n- second\n+ plus note\n--verbose")
        #expect(!list.isDiff && list.lines.allSatisfy { $0.kind == .plain })
        let edit = RelayToolPresentation(tool: "Edit",
            text: #"{"file_path":"/a/Models.swift","old_string":"let a = 1","new_string":"let a = 2\nlet b = 3"}"#)
        #expect(edit.isDiff && edit.title == "Edit · Models.swift")
        #expect(edit.lines == [.init(text: "-let a = 1", kind: .removed), .init(text: "+let a = 2", kind: .added),
                               .init(text: "+let b = 3", kind: .added)])
        let patch = RelayToolPresentation(tool: "apply_patch",
            text: "*** Begin Patch\n*** Update File: a.swift\n@@\n-old\n+new\n*** End Patch")
        #expect(patch.isDiff && patch.lines.map(\.kind) == [.header, .header, .hunk, .removed, .added, .header])
    }

    @Test func toolStatesCarryRoleSymbolAndWords() {
        let failed = RelayToolState(status: "failed", live: true)
        #expect(failed == .failed && failed.role == .danger && failed.role.symbol == "xmark.octagon.fill")
        #expect(failed.spoken == "Error: Failed")
        #expect(RelayToolState(status: "running", live: true) == .running)
        #expect(RelayToolState(status: "running", live: true).role.spokenName == "In progress")
        #expect(RelayToolState(status: "completed", live: false) == .done)
        #expect(RelayToolState(status: "completed", live: false).role == .neutral)
        // A historical call is never shown spinning.
        #expect(RelayToolState(status: "requested", live: false) == .other("Called"))
        #expect(RelayToolState(status: "running", live: false) == .other("Called"))
        #expect(RelayToolPresentation.elapsed(12) == "12 s")
        #expect(RelayToolPresentation.elapsed(125) == "2 min 5 s")
    }

    @Test func onlyTrailingUnansweredCallsAreLive() {
        let statuses: [String?] = [nil, "requested", "completed", "requested", "running"]
        #expect(RelayToolPresentation.liveIndices(statuses: statuses, active: true) == [3, 4])
        #expect(RelayToolPresentation.liveIndices(statuses: statuses, active: false).isEmpty)
        #expect(RelayToolPresentation.liveIndices(statuses: ["requested", nil], active: true).isEmpty)
    }

    @Test func toolTitlesSummariseArguments() {
        #expect(RelayToolPresentation(tool: "Bash", text: #"{"command":"git status","description":"Show status"}"#).title == "Bash · git status")
        #expect(RelayToolPresentation(tool: "Read", text: "{\n  \"file_path\": \"/x/Sources/Relay/Models.swift\"\n}").title == "Read · Models.swift")
        #expect(RelayToolPresentation(tool: "Read", text: #"{"file_path":"/x/Models.swift"}"#).lines.isEmpty)
        #expect(RelayToolPresentation(tool: "Grep", text: #"{"pattern":"headerActivityDetail","path":"Sources"}"#).title == "Grep · headerActivityDetail")
        #expect(RelayToolPresentation(tool: "shell", text: #"{"command":["bash","-lc","rg -n foo"]}"#).title == "shell · rg -n foo")
        #expect(RelayToolPresentation(tool: "Command", text: "git status\nOn branch main").title == "Command · git status")
        #expect(RelayToolPresentation(tool: "Command", text: "git status\nOn branch main").lines.map(\.text) == ["On branch main"])
        #expect(RelayToolPresentation(tool: "Tool result", text: "ok").title == "Result")
        #expect(RelayToolPresentation(tool: "Bash", text: "plain output").title == "Bash")
        let long = RelayToolPresentation(tool: "Bash", text: #"{"command":"\#(String(repeating: "x", count: 200))"}"#)
        #expect(long.title.count <= "Bash · ".count + 60)
    }

    @Test func rawInfrastructureErrorIsNotUserFacing() {
        let raw = "Host exec outcome unavailable; job job-5f0c. Do not replay execution. The network connection was lost."
        let shown = RelayConversationErrorText.userFacing(raw)
        #expect(shown.message == "Couldn't load the conversation from the host. Try again.")
        #expect(!shown.message.contains("job-") && !shown.message.contains("replay"))
        #expect(shown.detail == raw)
        let unbound = "This pane is not running a Claude or Codex session."
        #expect(RelayConversationErrorText.userFacing(unbound).message == unbound)
        #expect(RelayConversationErrorText.userFacing(unbound).detail == nil)
    }
}
