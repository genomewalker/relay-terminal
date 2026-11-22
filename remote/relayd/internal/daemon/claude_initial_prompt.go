package daemon

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/nativechat"
)

// This proof is constructed only for a kernel-bound, idle inspection. It is
// local to that inspection and authorizes omission, never replay, of one exact
// initial prompt. The ordinary resume builder continues to reject all prompts.
type phClaudeInitialPromptProof struct {
	session, text, argumentsSHA string
}

func phClaudeArgumentsSHA(arguments []string) string {
	data, _ := json.Marshal(arguments)
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func phClaudeTranscriptRevision(info os.FileInfo) string {
	dev, ino := phStatDevIno(info)
	digest := sha256.Sum256([]byte(fmt.Sprintf("%d:%d:%d:%d", dev, ino, info.Size(), phMtimeNs(info))))
	return hex.EncodeToString(digest[:])
}

func phProveClaudeInitialPrompt(path, session string, arguments []string, revision string, uid int, idle bool) *phClaudeInitialPromptProof {
	return phProveClaudeInitialPromptSince(path, session, arguments, revision, uid, idle, time.Time{})
}

// phClaudeInitialPromptRefusal is the refusal text; the desktop classifies it
// as initial_prompt_unproven.
const phClaudeInitialPromptRefusal = "The initial Claude prompt is not verified incorporated in an idle conversation."

// phResumedPromptLimit bounds the whole-transcript scan for a resumed launch.
const phResumedPromptLimit = 64 << 20

// phResumedPromptSkew tolerates the gap between Claude's own row timestamps
// and the kernel's process start on the same host.
const phResumedPromptSkew = 2 * time.Minute

// phProveClaudeInitialPromptSince also accepts one resumed shape: exactly one
// --resume or -r naming this bound session, and the prompt as the last
// argument. That is how an agent is relaunched with a one-off note. started is
// the verified agent process's kernel start; without it a resumed launch is
// never eligible.
func phProveClaudeInitialPromptSince(path, session string, arguments []string, revision string, uid int, idle bool, started time.Time) *phClaudeInitialPromptProof {
	fail := func() {
		phRaise(phValueError, phClaudeInitialPromptRefusal)
	}
	if !idle || !phSafeID.MatchString(session) || filepath.Base(path) != session+".jsonl" || len(arguments) < 2 {
		fail()
	}
	// A resumed/forked invocation can contain a new, still-pending prompt that
	// happens to match an old turn. An original launch is eligible, and so is
	// a resume of this exact session proven by phProveResumedClaudePrompt.
	resumed := false
	for pos := 1; pos < len(arguments); pos++ {
		key, value, equal := strings.Cut(arguments[pos], "=")
		if phContains([]string{"--continue", "-c", "--session-id", "--fork-session"}, key) {
			fail()
		}
		if key != "--resume" && key != "-r" {
			continue
		}
		if resumed || started.IsZero() {
			fail()
		}
		if !equal {
			// The selector's value can never be the prompt itself.
			if pos+1 >= len(arguments)-1 {
				fail()
			}
			pos++
			value = arguments[pos]
		}
		if value != session {
			fail()
		}
		resumed = true
	}
	prompt := arguments[len(arguments)-1]
	if prompt == "" || len(prompt) > 65536 || strings.HasPrefix(prompt, "-") {
		fail()
	}
	if resumed {
		return phProveResumedClaudePrompt(path, session, arguments, prompt, revision, uid, started, fail)
	}
	file := phOpenNoFollow(path)
	defer file.Close()
	before, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	if !before.Mode().IsRegular() || phStatUID(before) != uid || before.Mode().Perm()&0o022 != 0 ||
		revision == "" || phClaudeTranscriptRevision(before) != revision {
		fail()
	}
	// Read only the original turn, with a hard bound. A compacted, malformed,
	// incomplete, mismatched or unusually large prefix cannot grant authority.
	const limit = 8 << 20
	scanner := bufio.NewScanner(io.LimitReader(file, limit+1))
	scanner.Buffer(make([]byte, 4096), 1<<20)
	consumed := 0
	found, completed := false, false
	for scanner.Scan() {
		line := scanner.Bytes()
		consumed += len(line) + 1
		if consumed > limit {
			fail()
		}
		var row map[string]any
		if nativeJSONUnicode(line) != nil {
			fail()
		}
		if _, err := nativechat.DecodeObject(line, 1<<20); err != nil {
			fail()
		}
		if json.Unmarshal(line, &row) != nil {
			fail()
		}
		if row["isSidechain"] == true || row["isMeta"] == true {
			continue
		}
		kind, _ := row["type"].(string)
		if kind != "user" && kind != "assistant" && kind != "system" {
			continue
		}
		if row["isCompactSummary"] == true || row["isVisibleInTranscriptOnly"] == true {
			fail()
		}
		if kind == "user" || kind == "assistant" {
			if row["sessionId"] != session {
				fail()
			}
			message, ok := row["message"].(map[string]any)
			if !ok {
				fail()
			}
			if message["role"] != kind {
				fail()
			}
			if kind == "user" {
				if !found {
					if phClaudePromptText(message["content"]) != prompt {
						fail()
					}
					found = true
				} else if !phClaudeOnlyToolResults(message["content"]) {
					// A later historical match cannot stand in for the original
					// prompt's completed turn.
					fail()
				}
			} else {
				if !found {
					fail()
				}
				completed = message["stop_reason"] == "end_turn" || message["stop_reason"] == "stop_sequence"
			}
		} else if found && row["sessionId"] == session && row["subtype"] == "turn_duration" {
			completed = true
		}
		if completed {
			break
		}
	}
	if scanner.Err() != nil || !found || !completed {
		fail()
	}
	after, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	current, err := os.Lstat(path)
	if err != nil {
		phRaiseOS(err)
	}
	if phClaudeTranscriptRevision(after) != revision || !os.SameFile(before, current) ||
		phClaudeTranscriptRevision(current) != revision {
		fail()
	}
	return &phClaudeInitialPromptProof{session: session, text: prompt, argumentsSHA: phClaudeArgumentsSHA(arguments)}
}

func phClaudePromptText(content any) string {
	if text, ok := content.(string); ok {
		return text
	}
	blocks, ok := content.([]any)
	if !ok || len(blocks) != 1 {
		return ""
	}
	block, ok := blocks[0].(map[string]any)
	if !ok || block["type"] != "text" {
		return ""
	}
	text, _ := block["text"].(string)
	return text
}

func phClaudeOnlyToolResults(content any) bool {
	blocks, ok := content.([]any)
	if !ok || len(blocks) == 0 {
		return false
	}
	for _, raw := range blocks {
		block, ok := raw.(map[string]any)
		if !ok || block["type"] != "tool_result" {
			return false
		}
	}
	return true
}

// phProveResumedClaudePrompt proves that a resumed launch's prompt was
// submitted by this process and completed. The conversation identity comes
// from the caller's verified binding (session, transcript path, kernel
// process); the transcript only shows incorporation. The prompt must appear
// exactly once among the session's user turns, at or after the process start
// (an older matching turn cannot stand in for a still-pending prompt), and be
// followed by a completed assistant turn before any other user message.
func phProveResumedClaudePrompt(path, session string, arguments []string, prompt, revision string, uid int, started time.Time, fail func()) *phClaudeInitialPromptProof {
	file := phOpenNoFollow(path)
	defer file.Close()
	before, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	if !before.Mode().IsRegular() || phStatUID(before) != uid || before.Mode().Perm()&0o022 != 0 ||
		before.Size() > phResumedPromptLimit || revision == "" || phClaudeTranscriptRevision(before) != revision {
		fail()
	}
	scanner := bufio.NewScanner(io.LimitReader(file, phResumedPromptLimit+1))
	scanner.Buffer(make([]byte, 4096), 8<<20)
	consumed := 0
	matches := 0
	pending, completed := false, false
	for scanner.Scan() {
		line := scanner.Bytes()
		consumed += len(line) + 1
		if consumed > phResumedPromptLimit {
			fail()
		}
		var row map[string]any
		if nativeJSONUnicode(line) != nil {
			fail()
		}
		if _, err := nativechat.DecodeObject(line, 8<<20); err != nil {
			fail()
		}
		if json.Unmarshal(line, &row) != nil {
			fail()
		}
		if row["isSidechain"] == true || row["isMeta"] == true {
			continue
		}
		kind, _ := row["type"].(string)
		if kind != "user" && kind != "assistant" && kind != "system" {
			continue
		}
		if pending && (row["isCompactSummary"] == true || row["isVisibleInTranscriptOnly"] == true) {
			fail()
		}
		message, _ := row["message"].(map[string]any)
		switch {
		case kind == "user" && row["sessionId"] == session && message != nil && message["role"] == "user" &&
			row["isCompactSummary"] != true && row["isVisibleInTranscriptOnly"] != true &&
			phClaudePromptText(message["content"]) == prompt:
			matches++
			if matches > 1 {
				fail()
			}
			stamp, _ := row["timestamp"].(string)
			at, err := time.Parse(time.RFC3339Nano, stamp)
			if err != nil || at.Before(started.Add(-phResumedPromptSkew)) {
				fail()
			}
			pending = true
		case !pending:
			continue
		case kind == "user":
			if row["sessionId"] != session || message == nil || !phClaudeOnlyToolResults(message["content"]) {
				// Another prompt before the note's turn completed.
				fail()
			}
		case kind == "assistant":
			if row["sessionId"] != session || message == nil || message["role"] != "assistant" {
				fail()
			}
			if message["stop_reason"] == "end_turn" || message["stop_reason"] == "stop_sequence" {
				pending, completed = false, true
			}
		case row["sessionId"] == session && row["subtype"] == "turn_duration":
			pending, completed = false, true
		}
	}
	// A transcript that ends with the prompt still pending refuses, even idle.
	if scanner.Err() != nil || matches != 1 || pending || !completed {
		fail()
	}
	after, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	current, err := os.Lstat(path)
	if err != nil {
		phRaiseOS(err)
	}
	if phClaudeTranscriptRevision(after) != revision || !os.SameFile(before, current) ||
		phClaudeTranscriptRevision(current) != revision {
		fail()
	}
	return &phClaudeInitialPromptProof{session: session, text: prompt, argumentsSHA: phClaudeArgumentsSHA(arguments)}
}
