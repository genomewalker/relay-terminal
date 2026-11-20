package daemon

import (
	"strings"
	"testing"
)

func cardRows(t *testing.T, kind string, rows ...string) []*pyObject {
	t.Helper()
	names, calls := newPyObject(), newConversationCalls()
	var items []*pyObject
	for i, raw := range rows {
		row := phLoads(raw).(*pyObject)
		offset := int64(i * 100)
		parsed := parseConversationRow(row, kind, "s1", offset, names)
		before := string(pyEncode(parsed, conversationJSON))
		count := len(parsed.items)
		parsed = withConversationCards(row, kind, "s1", offset, parsed, calls)
		// The card pass only adds card/call_id fields or new Codex items; the
		// parsed items the reference corpus pins are otherwise unchanged.
		stripped := pyListOf()
		for index, raw := range parsed.items {
			item := raw.(*pyObject)
			if index < count {
				copy := item.Copy()
				copy.Delete("card")
				copy.Delete("call_id")
				stripped.items = append(stripped.items, copy)
			}
			items = append(items, item)
		}
		if got := string(pyEncode(stripped, conversationJSON)); got != before {
			t.Fatalf("card pass rewrote parsed items:\n got %s\nwant %s", got, before)
		}
	}
	return items
}

func cardOf(t *testing.T, items []*pyObject, id string) *pyObject {
	t.Helper()
	for _, item := range items {
		if conversationString(item.Get("id")) == id {
			card, _ := item.Get("card").(*pyObject)
			return card
		}
	}
	t.Fatalf("no item %s in %d items", id, len(items))
	return nil
}

const claudeBashCall = `{"type":"assistant","uuid":"a1","sessionId":"s1","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"npm test -- preview","description":"run"}}]}}`

func TestConversationCardClaudeBashKeepsStreamsAndToolError(t *testing.T) {
	result := `{"type":"user","uuid":"u1","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"3 checks passed","is_error":true}]},"toolUseResult":{"stdout":"3 checks passed","stderr":"Warning: cold cache","interrupted":false,"isImage":false}}`
	items := cardRows(t, "claude", claudeBashCall, result)
	card := cardOf(t, items, "u1:tool:0")
	if card == nil || card.Get("kind") != "shell" || card.Get("command") != "npm test -- preview" ||
		card.Get("stdout") != "3 checks passed" || card.Get("stderr") != "Warning: cold cache" || card.Get("tool_error") != true {
		t.Fatalf("shell card = %s", pyEncode(card, conversationJSON))
	}
	// Claude reports no exit status or duration; the card never invents them.
	if card.Has("exit_code") || card.Has("duration_ms") || card.Has("interrupted") {
		t.Fatalf("invented fields: %s", pyEncode(card, conversationJSON))
	}
	if cardOf(t, items, "a1:tool:0") != nil {
		t.Fatal("the call item must not carry a card")
	}
	for _, item := range items {
		if item.Get("call_id") != "tu1" {
			t.Fatalf("call and result must share call_id: %s", pyEncode(item, conversationJSON))
		}
	}
}

func TestConversationCardClaudeEditUsesReportedPatch(t *testing.T) {
	call := `{"type":"assistant","uuid":"a2","sessionId":"s1","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"tu2","name":"Edit","input":{"file_path":"/w/src/preview.ts","old_string":"a","new_string":"b"}}]}}`
	result := `{"type":"user","uuid":"u2","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","content":"ok"}]},"toolUseResult":{"filePath":"/w/src/preview.ts","oldString":"a","newString":"b","originalFile":"SECRET WHOLE FILE","structuredPatch":[{"oldStart":24,"oldLines":3,"newStart":24,"newLines":4,"lines":["  return {","-  title: \"Nothing\",","+  title: \"No items\",","+  hint: \"Select one\","]}],"userModified":false}}`
	items := cardRows(t, "claude", call, result)
	card := cardOf(t, items, "u2:tool:0")
	encoded := string(pyEncode(card, conversationJSON))
	if strings.Contains(encoded, "SECRET") {
		t.Fatal("originalFile must never leave the host")
	}
	file := card.Get("files").(*pyList).items[0].(*pyObject)
	hunk := file.Get("hunks").(*pyList).items[0].(*pyObject)
	if file.Get("path") != "/w/src/preview.ts" || file.Get("change") != "update" || file.Get("added") != int64(2) ||
		file.Get("removed") != int64(1) || file.Has("inferred") || hunk.Get("header") != "@@ -24,3 +24,4 @@" || len(hunk.Get("lines").(*pyList).items) != 4 {
		t.Fatalf("edit card = %s", encoded)
	}
}

func TestConversationCardClaudeEditWithoutPatchIsInferred(t *testing.T) {
	call := `{"type":"assistant","uuid":"a3","sessionId":"s1","message":{"content":[{"type":"tool_use","id":"tu3","name":"Edit","input":{"file_path":"/w/a.go","old_string":"x := 1","new_string":"x := 2"}}]}}`
	result := `{"type":"user","uuid":"u3","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu3","content":"ok"}]},"toolUseResult":{"filePath":"/w/a.go","oldString":"x := 1","newString":"x := 2","structuredPatch":[]}}`
	file := cardOf(t, cardRows(t, "claude", call, result), "u3:tool:0").Get("files").(*pyList).items[0].(*pyObject)
	if file.Get("inferred") != true || file.Get("added") != int64(1) || file.Get("removed") != int64(1) {
		t.Fatalf("inferred card = %s", pyEncode(file, conversationJSON))
	}
}

func TestConversationCardClaudeWriteCreateAndFallbacks(t *testing.T) {
	call := `{"type":"assistant","uuid":"a4","sessionId":"s1","message":{"content":[{"type":"tool_use","id":"tu4","name":"Write","input":{"file_path":"/w/new.md","content":"one\ntwo\n"}}]}}`
	created := `{"type":"user","uuid":"u4","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu4","content":"ok"}]},"toolUseResult":{"type":"create","filePath":"/w/new.md","content":"one\ntwo\n","structuredPatch":[]}}`
	file := cardOf(t, cardRows(t, "claude", call, created), "u4:tool:0").Get("files").(*pyList).items[0].(*pyObject)
	if file.Get("change") != "add" || file.Get("added") != int64(2) || file.Get("removed") != int64(0) {
		t.Fatalf("create card = %s", pyEncode(file, conversationJSON))
	}
	// A string toolUseResult (an error) and an unknown tool both keep the generic row.
	failed := `{"type":"user","uuid":"u5","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu4","content":"Error","is_error":true}]},"toolUseResult":"Error: file changed"}`
	if cardOf(t, cardRows(t, "claude", call, failed), "u5:tool:0") != nil {
		t.Fatal("string result must fall back")
	}
	grepCall := `{"type":"assistant","uuid":"a6","sessionId":"s1","message":{"content":[{"type":"tool_use","id":"tu6","name":"Grep","input":{"pattern":"x"}}]}}`
	grepResult := `{"type":"user","uuid":"u6","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu6","content":"a.go"}]},"toolUseResult":{"mode":"files","filenames":["a.go"]}}`
	if cardOf(t, cardRows(t, "claude", grepCall, grepResult), "u6:tool:0") != nil {
		t.Fatal("unknown tools keep the generic row")
	}
	// Two results in one row cannot be attributed to the row-level toolUseResult.
	two := `{"type":"user","uuid":"u7","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"a"},{"type":"tool_result","tool_use_id":"tu4","content":"b"}]},"toolUseResult":{"stdout":"a","stderr":""}}`
	for _, item := range cardRows(t, "claude", claudeBashCall, call, two) {
		if item.Has("card") {
			t.Fatalf("ambiguous result got a card: %s", pyEncode(item, conversationJSON))
		}
	}
	// Sidechain rows are not this conversation.
	side := strings.Replace(created, `"uuid":"u4"`, `"uuid":"u8","isSidechain":true`, 1)
	if len(cardRows(t, "claude", call, side)) != 1 {
		t.Fatal("sidechain result must not appear")
	}
}

func TestConversationCardCodexCommandExecution(t *testing.T) {
	row := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","go test ./..."],"cwd":"/w","status":"failed","aggregated_output":"FAIL x\n","exit_code":1,"duration":{"secs":1,"nanos":800000000}}}}`
	items := cardRows(t, "codex", row)
	if len(items) != 1 || items[0].Get("tool_name") != "Command" || items[0].Get("tool_status") != "failed" ||
		items[0].Get("text") != "go test ./...\nFAIL x\n" {
		t.Fatalf("command item = %s", pyEncode(pyListOf(items[0]), conversationJSON))
	}
	card := items[0].Get("card").(*pyObject)
	if card.Get("command") != "go test ./..." || card.Get("output") != "FAIL x\n" || card.Get("exit_code") != int64(1) || card.Get("duration_ms") != int64(1800) {
		t.Fatalf("command card = %s", pyEncode(card, conversationJSON))
	}
	// Absent exit code and duration stay absent.
	bare := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c2","command":["ls"],"status":"completed"}}}`
	card = cardRows(t, "codex", bare)[0].Get("card").(*pyObject)
	if card.Get("command") != "ls" || card.Has("exit_code") || card.Has("duration_ms") || card.Has("output") {
		t.Fatalf("bare card = %s", pyEncode(card, conversationJSON))
	}
	// Other item types are already read from response items; malformed commands add nothing.
	for _, other := range []string{
		`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"text","text":"hi"}]}}}`,
		`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c3","command":"ls"}}}`,
		`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c4","command":[1,2]}}}`,
		`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f9","changes":{"/a":{"type":"rename"}}}}}`,
		`{"type":"event_msg","payload":{"type":"item_completed","item":"x"}}`,
	} {
		if got := cardRows(t, "codex", other); len(got) != 0 {
			t.Fatalf("%s produced %s", other, pyEncode(pyListOf(got[0]), conversationJSON))
		}
	}
}

func TestConversationCardCodexFileChange(t *testing.T) {
	row := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f1","status":"completed","changes":{` +
		`"/w/src/a.swift":{"type":"update","unified_diff":"--- a/src/a.swift\n+++ b/src/a.swift\n@@ -1,2 +1,2 @@\n line\n-old\n+new\n@@ -9 +9,2 @@\n+added\n ctx\n","move_path":null},` +
		`"/w/src/b.swift":{"type":"add","content":"x\ny\nz\n"}}}}}`
	items := cardRows(t, "codex", row)
	if len(items) != 1 || items[0].Get("tool_name") != "File changes" || items[0].Get("text") != "update /w/src/a.swift\nadd /w/src/b.swift" {
		t.Fatalf("file item = %s", pyEncode(pyListOf(items[0]), conversationJSON))
	}
	files := items[0].Get("card").(*pyObject).Get("files").(*pyList).items
	update, add := files[0].(*pyObject), files[1].(*pyObject)
	hunks := update.Get("hunks").(*pyList).items
	if update.Get("added") != int64(2) || update.Get("removed") != int64(1) || len(hunks) != 2 ||
		hunks[0].(*pyObject).Get("header") != "@@ -1,2 +1,2 @@" || update.Has("move_path") {
		t.Fatalf("update = %s", pyEncode(update, conversationJSON))
	}
	if add.Get("change") != "add" || add.Get("added") != int64(3) {
		t.Fatalf("add = %s", pyEncode(add, conversationJSON))
	}
}

func TestConversationCardBoundsKeepTrueCounts(t *testing.T) {
	var diff strings.Builder
	diff.WriteString("@@ -1,1 +1,1000 @@\n")
	for i := 0; i < 1000; i++ {
		diff.WriteString("+" + strings.Repeat("x", 2000) + "\n")
	}
	output := strings.Repeat("line of output\n", 5000) + "final error"
	rows := []string{
		`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f2","changes":{"/w/big.txt":{"type":"update","unified_diff":` + string(pyEncode(diff.String(), conversationJSON)) + `}}}}}`,
		`{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c5","command":["make"],"aggregated_output":` + string(pyEncode(output, conversationJSON)) + `,"exit_code":2}}}`,
	}
	items := cardRows(t, "codex", rows...)
	file := items[0].Get("card").(*pyObject).Get("files").(*pyList).items[0].(*pyObject)
	lines := file.Get("hunks").(*pyList).items[0].(*pyObject).Get("lines").(*pyList).items
	shownBytes := 0
	for _, line := range lines {
		shownBytes += len(line.(string)) + 1
	}
	// Both the line and the byte budget bound the display; counts stay true.
	if file.Get("added") != int64(1000) || len(lines) == 0 || len(lines) > cardMaxDiffLines || shownBytes > cardMaxDiffBytes ||
		file.Get("omitted_lines") != int64(1000-len(lines)) || len([]rune(lines[0].(string))) != cardMaxLineRunes {
		t.Fatalf("diff bounds: added=%v shown=%d omitted=%v first=%d", file.Get("added"), len(lines), file.Get("omitted_lines"), len([]rune(lines[0].(string))))
	}
	shell := items[1].Get("card").(*pyObject)
	kept := conversationString(shell.Get("output"))
	if len(kept) > cardMaxOutputBytes || !strings.HasSuffix(kept, "final error") || shell.Get("output_truncated") != true ||
		len(conversationString(items[1].Get("text"))) > cardMaxCommand+cardMaxOutputBytes+1 {
		t.Fatalf("output bounds: %d bytes, truncated=%v", len(kept), shell.Get("output_truncated"))
	}
	if size := len(pyEncode(pyListOf(items[0], items[1]), conversationJSON)); size > 400<<10 {
		t.Fatalf("cards too large: %d bytes", size)
	}
}

func TestConversationCardDiffBudgetIsSharedAcrossFiles(t *testing.T) {
	changes := []string{}
	for i := 0; i < 16; i++ {
		var diff strings.Builder
		diff.WriteString("@@ -1 +1,300 @@\n")
		for j := 0; j < 300; j++ {
			diff.WriteString("+" + strings.Repeat("y", 1000) + "\n")
		}
		changes = append(changes, `"/w/f`+pyStr(int64(i))+`":{"type":"update","unified_diff":`+string(pyEncode(diff.String(), conversationJSON))+`}`)
	}
	row := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f3","changes":{` + strings.Join(changes, ",") + `}}}}`
	item := cardRows(t, "codex", row)[0]
	if size := len(pyEncode(item.Get("card"), conversationJSON)); size > cardMaxDiffBytes+16<<10 {
		t.Fatalf("card is %d bytes", size)
	}
	files := item.Get("card").(*pyObject).Get("files").(*pyList).items
	if len(files) != 16 || files[15].(*pyObject).Get("added") != int64(300) || files[15].(*pyObject).Get("omitted_lines") != int64(300) {
		t.Fatalf("later files keep true counts and report omitted lines: %s", pyEncode(files[15].(*pyObject).Get("omitted_lines"), conversationJSON))
	}
}
