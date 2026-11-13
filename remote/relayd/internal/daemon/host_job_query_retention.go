package daemon

import (
	"encoding/json"
	"path"
	"strings"
	"time"
)

// The Relay app runs its periodic read-only checks (link requests, notices,
// agent binding and maintenance) as host jobs, a few hundred an hour on a
// busy host. Their records hold nothing a later reader needs, so a finished
// one is deleted an hour after it ends instead of after the host retention.
// Its tombstone keeps the job ID reserved as for any other deleted job.
const (
	hostJobRetentionQuery    = "query"
	hostJobQueryRetentionAge = time.Hour
)

// Read-only owner operations the app polls through `relayd communication`.
var hostJobQueryOperations = map[string]bool{
	"route_desktop_link_list": true,
	"desktop_link_status":     true,
	"question_notices":        true,
	"work_native_pending":     true,
	"receipt":                 true,
	"remote_receipt":          true,
	"group_receipt":           true,
	"list":                    true,
	"discover":                true,
	"node_identity":           true,
}

// Read-only relayd subcommands the app polls per pane.
var hostJobQueryVerbs = map[string]bool{
	"agent-binding":     true,
	"agent-harnesses":   true,
	"agent-maintenance": true,
}

// The remote form RelayHostExecution.communicationCommand builds: the
// installed helper when present, else the installed relayd.
const (
	hostJobQueryHelperPrefix = `if [ -x "$HOME/.local/share/relay/bin/relayd-communication" ]; then "$HOME/.local/share/relay/bin/relayd-communication" communication; else `
	hostJobQueryHelperSuffix = `; fi`
)

// hostJobQueryRetention returns hostJobRetentionQuery when r is exactly one
// of the app's read-only queries, and "" otherwise. Anything it does not
// recognise keeps the host retention.
func hostJobQueryRetention(r hostRequest) string {
	if r.Kind != "" || r.Listener != nil || r.KeepStdin || len(r.Argv) > 0 || r.Command == "" {
		return ""
	}
	command := r.Command
	helper := false
	if rest, ok := strings.CutPrefix(command, hostJobQueryHelperPrefix); ok {
		inner, ok := strings.CutSuffix(rest, hostJobQueryHelperSuffix)
		if !ok {
			return ""
		}
		command, helper = inner, true
	}
	words, ok := hostJobQueryWords(command)
	if !ok || len(words) < 2 || path.Base(words[0]) != "relayd" {
		return ""
	}
	verb := words[1]
	if verb == "communication" {
		if len(words) != 2 || !hostJobQueryOperations[hostJobQueryOperation(r.Stdin)] {
			return ""
		}
		return hostJobRetentionQuery
	}
	if helper || !hostJobQueryVerbs[verb] {
		return ""
	}
	return hostJobRetentionQuery
}

func hostJobQueryOperation(stdin []byte) string {
	var packet struct {
		Operation string `json:"operation"`
	}
	if json.Unmarshal(stdin, &packet) != nil {
		return ""
	}
	return packet.Operation
}

// hostJobQueryWords splits the command forms RelayHostExecution builds:
// space-separated words that are bare ([A-Za-z0-9_./-]), single-quoted
// (with the '\” escape), or the double-quoted "$HOME/..." executable.
// Any other shell syntax is refused.
func hostJobQueryWords(command string) ([]string, bool) {
	var words []string
	for _, field := range strings.Split(command, " ") {
		if field == "" {
			return nil, false
		}
		word, ok := hostJobQueryWord(field)
		if !ok {
			return nil, false
		}
		words = append(words, word)
	}
	return words, true
}

func hostJobQueryWord(field string) (string, bool) {
	if strings.HasPrefix(field, `"`) {
		inner, ok := strings.CutSuffix(field[1:], `"`)
		rest, home := strings.CutPrefix(inner, "$HOME/")
		if !ok || !home || !hostJobQueryBare(rest) {
			return "", false
		}
		return inner, true
	}
	if strings.HasPrefix(field, "'") {
		var word strings.Builder
		for _, part := range strings.Split(field, `'\''`) {
			word.WriteString(part)
		}
		joined := word.String()
		if len(joined) < 2 || joined[0] != '\'' || joined[len(joined)-1] != '\'' {
			return "", false
		}
		inner := joined[1 : len(joined)-1]
		if strings.Contains(inner, "'") {
			return "", false
		}
		return inner, true
	}
	if !hostJobQueryBare(field) {
		return "", false
	}
	return field, true
}

func hostJobQueryBare(word string) bool {
	if word == "" {
		return false
	}
	for _, c := range word {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("_./-", c)) {
			return false
		}
	}
	return true
}
