package daemon

import (
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Structured cards for file edits and shell commands. They are added after
// parseConversationRow so its output, which the reference corpus pins, stays
// unchanged. A card is optional; without one the timeline shows its existing
// generic tool row. Every value here comes from a provider transcript and is
// bounded before it leaves the host.
const (
	cardMaxFiles       = 16
	cardMaxDiffLines   = 400
	cardMaxDiffBytes   = 48 << 10
	cardMaxLineRunes   = 512
	cardMaxOutputBytes = 12 << 10
	cardMaxCommand     = 4096
	cardMaxPath        = 4096
	cardMaxCalls       = 4096
)

// conversationCalls remembers recent Claude tool calls by tool_use id so a
// later result can name its command or file. Bounded like the tool-name map.
type conversationCalls struct {
	order []string
	calls map[string]conversationCall
}

type conversationCall struct{ name, command, path, oldText, newText string }

func newConversationCalls() *conversationCalls {
	return &conversationCalls{calls: map[string]conversationCall{}}
}

func (c *conversationCalls) remember(id string, call conversationCall) {
	if id == "" || len(id) > 256 {
		return
	}
	if _, ok := c.calls[id]; !ok {
		c.order = append(c.order, id)
	}
	c.calls[id] = call
	for len(c.order) > cardMaxCalls {
		delete(c.calls, c.order[0])
		c.order = c.order[1:]
	}
}

// withConversationCards annotates parsed items, or adds Codex command and file
// items, for one transcript row. Malformed or unknown shapes add nothing.
func withConversationCards(row *pyObject, kind, session string, offset int64, parsed *pyList, calls *conversationCalls) *pyList {
	if kind == "claude" {
		claudeCards(row, session, parsed, calls)
		return parsed
	}
	if item := codexCardItem(row, offset); item != nil {
		parsed.items = append(parsed.items, item)
	}
	return parsed
}

// Claude tool items are numbered in block order over tool_use and tool_result
// blocks, exactly as conversationTextBlocks emits them.
func claudeCards(row *pyObject, session string, parsed *pyList, calls *conversationCalls) {
	if !pyEqual(row.Get("sessionId"), session) || pyTruthy(row.Get("isSidechain")) {
		return
	}
	message, ok := row.Get("message").(*pyObject)
	if !ok {
		return
	}
	blocks, ok := message.Get("content").(*pyList)
	if !ok {
		return
	}
	stable := conversationString(row.Get("uuid"))
	if stable == "" {
		return
	}
	byID := map[string]*pyObject{}
	for _, raw := range parsed.items {
		if item, ok := raw.(*pyObject); ok {
			byID[conversationString(item.Get("id"))] = item
		}
	}
	tool, results := 0, 0
	type pending struct {
		item  *pyObject
		id    string
		error bool
	}
	var result *pending
	for i, raw := range blocks.items {
		if i >= 256 || tool >= 64 {
			break
		}
		block, ok := raw.(*pyObject)
		if !ok {
			continue
		}
		switch block.Get("type") {
		case "tool_use":
			id := conversationString(block.Get("id"))
			call := conversationCall{name: conversationString(block.Get("name"))}
			if input, ok := block.Get("input").(*pyObject); ok {
				call.command = cardClip(conversationString(input.Get("command")), cardMaxCommand)
				call.path = cardPath(conversationString(input.Get("file_path")))
				call.oldText = conversationString(input.Get("old_string"))
				call.newText = conversationString(input.Get("new_string"))
			}
			calls.remember(id, call)
			if item := byID[stable+":tool:"+pyStr(int64(tool))]; item != nil && id != "" && len(id) <= 256 {
				item.Set("call_id", id)
			}
			tool++
		case "tool_result":
			id := conversationString(block.Get("tool_use_id"))
			if item := byID[stable+":tool:"+pyStr(int64(tool))]; item != nil && id != "" && len(id) <= 256 {
				item.Set("call_id", id)
				result = &pending{item, id, pyTruthy(block.Get("is_error"))}
			}
			results++
			tool++
		}
	}
	// toolUseResult belongs to the row, so it is attributable only when the
	// row carries exactly one result.
	if results != 1 || result == nil {
		return
	}
	detail, ok := row.Get("toolUseResult").(*pyObject)
	if !ok {
		return
	}
	call, known := calls.calls[result.id]
	if !known {
		return
	}
	var card *pyObject
	switch call.name {
	case "Bash":
		card = claudeShellCard(call, detail, result.error)
	case "Edit", "MultiEdit", "Write":
		if !result.error {
			card = claudeEditCard(call, detail)
		}
	}
	if card != nil {
		result.item.Set("card", card)
	}
}

func claudeShellCard(call conversationCall, detail *pyObject, failed bool) *pyObject {
	stdout, okOut := detail.Get("stdout").(string)
	stderr, okErr := detail.Get("stderr").(string)
	if !okOut && !okErr {
		return nil
	}
	card := pyObj("kind", "shell")
	if call.command != "" {
		card.Set("command", call.command)
	}
	truncated := false
	if okOut && stdout != "" {
		text, cut := cardTail(stdout)
		card.Set("stdout", text)
		truncated = truncated || cut
	}
	if okErr && stderr != "" {
		text, cut := cardTail(stderr)
		card.Set("stderr", text)
		truncated = truncated || cut
	}
	if pyTruthy(detail.Get("interrupted")) {
		card.Set("interrupted", true)
	}
	// Claude reports a failed tool call, not a process exit status.
	if failed {
		card.Set("tool_error", true)
	}
	if truncated {
		card.Set("output_truncated", true)
	}
	return card
}

func claudeEditCard(call conversationCall, detail *pyObject) *pyObject {
	path := cardPath(conversationString(detail.Get("filePath")))
	if path == "" {
		path = call.path
	}
	if path == "" {
		return nil
	}
	file := cardFile{path: path, change: "update", budget: newCardBudget()}
	if patch, ok := detail.Get("structuredPatch").(*pyList); ok && len(patch.items) > 0 {
		for _, raw := range patch.items {
			hunk, ok := raw.(*pyObject)
			if !ok {
				return nil
			}
			lines, ok := hunk.Get("lines").(*pyList)
			if !ok {
				return nil
			}
			oldStart, _ := pyInt(hunk.Get("oldStart"))
			oldLines, _ := pyInt(hunk.Get("oldLines"))
			newStart, _ := pyInt(hunk.Get("newStart"))
			newLines, _ := pyInt(hunk.Get("newLines"))
			text := make([]string, 0, len(lines.items))
			for _, line := range lines.items {
				value, ok := line.(string)
				if !ok {
					return nil
				}
				text = append(text, value)
			}
			file.add(fmt.Sprintf("@@ -%d,%d +%d,%d @@", oldStart, oldLines, newStart, newLines), text)
		}
	} else if pyEqual(detail.Get("type"), "create") {
		content, ok := detail.Get("content").(string)
		if !ok {
			return nil
		}
		file.change = "add"
		file.addContent(content)
	} else if oldText, newText := conversationString(detail.Get("oldString")), conversationString(detail.Get("newString")); oldText != "" || newText != "" {
		// No reported patch: a before/after view of the edit, marked as such.
		file.inferred = true
		file.addPair(oldText, newText)
	} else if call.oldText != "" || call.newText != "" {
		file.inferred = true
		file.addPair(call.oldText, call.newText)
	}
	return editCard([]*cardFile{&file}, 0)
}

// codexCardItem turns a completed Codex command or file change into a tool
// item. Other item types are already read from response items.
func codexCardItem(row *pyObject, offset int64) *pyObject {
	if !pyEqual(row.Get("type"), "event_msg") {
		return nil
	}
	payload, ok := row.Get("payload").(*pyObject)
	if !ok || !pyEqual(payload.Get("type"), "item_completed") {
		return nil
	}
	item, ok := payload.Get("item").(*pyObject)
	if !ok {
		return nil
	}
	id := conversationString(item.Get("id"))
	if id == "" || len(id) > 200 {
		id = pyStr(offset)
	}
	status := conversationString(item.Get("status"))
	if status != "failed" {
		status = "completed"
	}
	switch item.Get("type") {
	case "CommandExecution":
		card := codexShellCard(item)
		if card == nil {
			return nil
		}
		text := conversationString(card.Get("command"))
		if output := conversationString(card.Get("output")); output != "" {
			text += "\n" + output
		}
		return pyObj("id", id+":command", "role", "tool", "text", text, "tool_name", "Command", "tool_status", status,
			"revision", offset+1, "card", card)
	case "FileChange":
		card, summary := codexEditCard(item)
		if card == nil {
			return nil
		}
		return pyObj("id", id+":file-change", "role", "tool", "text", summary, "tool_name", "File changes", "tool_status", status,
			"revision", offset+1, "card", card)
	}
	return nil
}

func codexShellCard(item *pyObject) *pyObject {
	parts, ok := item.Get("command").(*pyList)
	if !ok || len(parts.items) == 0 {
		return nil
	}
	argv := make([]string, 0, len(parts.items))
	for _, raw := range parts.items {
		part, ok := raw.(string)
		if !ok {
			return nil
		}
		argv = append(argv, part)
	}
	command := strings.Join(argv, " ")
	// Codex runs commands as [shell, -lc, command].
	if len(argv) == 3 && strings.HasPrefix(argv[1], "-") && strings.HasSuffix(argv[1], "c") &&
		phContains([]string{"bash", "zsh", "sh"}, filepath.Base(argv[0])) {
		command = argv[2]
	}
	card := pyObj("kind", "shell", "command", cardClip(command, cardMaxCommand))
	if output, ok := item.Get("aggregated_output").(string); ok && output != "" {
		text, cut := cardTail(output)
		card.Set("output", text)
		if cut {
			card.Set("output_truncated", true)
		}
	}
	if code, ok := pyInt(item.Get("exit_code")); ok && code >= -1<<31 && code < 1<<31 {
		card.Set("exit_code", code)
	}
	if duration, ok := item.Get("duration").(*pyObject); ok {
		secs, okSecs := pyInt(duration.Get("secs"))
		nanos, okNanos := pyInt(duration.Get("nanos"))
		if okSecs && okNanos && secs >= 0 && secs < 1<<40 && nanos >= 0 && nanos < 1e9 {
			card.Set("duration_ms", secs*1000+nanos/1e6)
		}
	}
	return card
}

func codexEditCard(item *pyObject) (*pyObject, string) {
	changes, ok := item.Get("changes").(*pyObject)
	if !ok || changes.Len() == 0 {
		return nil, ""
	}
	var files []*cardFile
	var summary []string
	omitted := 0
	budget := newCardBudget()
	for _, path := range changes.Keys() {
		change, ok := changes.Get(path).(*pyObject)
		if !ok {
			return nil, ""
		}
		if len(files) >= cardMaxFiles {
			omitted++
			continue
		}
		file := &cardFile{path: cardPath(path), change: conversationString(change.Get("type")), budget: budget}
		if file.path == "" {
			return nil, ""
		}
		switch file.change {
		case "update":
			diff, _ := change.Get("unified_diff").(string)
			file.addUnified(diff)
			if move := cardPath(conversationString(change.Get("move_path"))); move != "" {
				file.movePath = move
			}
		case "add":
			content, _ := change.Get("content").(string)
			file.addContent(content)
		case "delete":
		default:
			return nil, ""
		}
		files = append(files, file)
		summary = append(summary, file.change+" "+file.path)
	}
	return editCard(files, omitted), cardClip(strings.Join(summary, "\n"), 8192)
}

// cardFile accumulates one file's hunks under the shared line budget. Counts
// cover every line, including those dropped from the display.
type cardFile struct {
	path, change, movePath string
	added, removed         int64
	hunks                  []*pyObject
	omitted                int64
	inferred               bool
	budget                 *cardBudget
}

// cardBudget bounds the displayed diff across every file of one card.
type cardBudget struct{ lines, bytes int }

func newCardBudget() *cardBudget {
	return &cardBudget{lines: cardMaxDiffLines, bytes: cardMaxDiffBytes}
}

func (f *cardFile) add(header string, lines []string) {
	display := pyListOf()
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "+"):
			f.added++
		case strings.HasPrefix(line, "-"):
			f.removed++
		}
		shown := cardClip(line, cardMaxLineRunes)
		if f.budget.lines <= 0 || f.budget.bytes < len(shown)+1 {
			f.budget.lines = 0
			f.omitted++
			continue
		}
		display.items = append(display.items, shown)
		f.budget.lines--
		f.budget.bytes -= len(shown) + 1
	}
	if len(display.items) > 0 || f.budget.lines > 0 {
		f.hunks = append(f.hunks, pyObj("header", cardClip(header, cardMaxLineRunes), "lines", display))
	}
}

func (f *cardFile) addContent(content string) {
	if content == "" {
		return
	}
	lines := strings.Split(strings.TrimSuffix(content, "\n"), "\n")
	for i := range lines {
		lines[i] = "+" + lines[i]
	}
	f.add(fmt.Sprintf("@@ -0,0 +1,%d @@", len(lines)), lines)
}

func (f *cardFile) addPair(oldText, newText string) {
	var lines []string
	if oldText != "" {
		for _, line := range strings.Split(oldText, "\n") {
			lines = append(lines, "-"+line)
		}
	}
	if newText != "" {
		for _, line := range strings.Split(newText, "\n") {
			lines = append(lines, "+"+line)
		}
	}
	f.add("", lines)
}

// addUnified reads hunks from a unified diff; file header lines are skipped.
func (f *cardFile) addUnified(diff string) {
	var header string
	var lines []string
	started := false
	for _, line := range strings.Split(strings.TrimSuffix(diff, "\n"), "\n") {
		if strings.HasPrefix(line, "@@") {
			if started {
				f.add(header, lines)
			}
			header, lines, started = line, nil, true
			continue
		}
		if !started {
			continue
		}
		lines = append(lines, line)
	}
	if started {
		f.add(header, lines)
	}
}

func editCard(files []*cardFile, omittedFiles int) *pyObject {
	list := pyListOf()
	for _, f := range files {
		hunks := pyListOf()
		for _, hunk := range f.hunks {
			hunks.items = append(hunks.items, hunk)
		}
		entry := pyObj("path", f.path, "change", f.change, "added", f.added, "removed", f.removed, "hunks", hunks)
		if f.movePath != "" {
			entry.Set("move_path", f.movePath)
		}
		if f.omitted > 0 {
			entry.Set("omitted_lines", f.omitted)
		}
		if f.inferred {
			entry.Set("inferred", true)
		}
		list.items = append(list.items, entry)
	}
	card := pyObj("kind", "edit", "files", list)
	if omittedFiles > 0 {
		card.Set("omitted_files", int64(omittedFiles))
	}
	return card
}

func cardPath(path string) string {
	if path == "" || len(path) > cardMaxPath || strings.ContainsRune(path, 0) || !utf8.ValidString(path) {
		return ""
	}
	return path
}

func cardClip(text string, runes int) string {
	if utf8.RuneCountInString(text) <= runes {
		return text
	}
	return conversationPrefix(text, runes-1) + "…"
}

// cardTail keeps the end of command output, where results and errors appear,
// starting on a line boundary when one is near.
func cardTail(text string) (string, bool) {
	if len(text) <= cardMaxOutputBytes {
		return text, false
	}
	cut := len(text) - cardMaxOutputBytes
	for cut < len(text) && !utf8.RuneStart(text[cut]) {
		cut++
	}
	tail := text[cut:]
	if newline := strings.IndexByte(tail, '\n'); newline >= 0 && newline < 512 {
		tail = tail[newline+1:]
	}
	return tail, true
}
