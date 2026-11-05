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
	fail := func() {
		phRaise(phValueError, "The initial Claude prompt is not verified incorporated in an idle conversation.")
	}
	if !idle || !phSafeID.MatchString(session) || filepath.Base(path) != session+".jsonl" || len(arguments) < 2 {
		fail()
	}
	// A resumed/forked invocation can contain a new, still-pending prompt that
	// happens to match an old turn. Only an original launch is eligible.
	for _, argument := range arguments[1:] {
		key, _, _ := strings.Cut(argument, "=")
		if phContains([]string{"--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"}, key) {
			fail()
		}
	}
	prompt := arguments[len(arguments)-1]
	if prompt == "" || len(prompt) > 65536 || strings.HasPrefix(prompt, "-") {
		fail()
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
