package daemon

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/relay-terminal/relayd/internal/contextusage"
)

// The exact conversation reader has already verified that the provider owns
// the transcript. A context-only refresh does not parse its conversation.
const conversationContextTail = 1 << 20

func codexConversationContext(tail []byte, partial bool) contextusage.Counts {
	if partial {
		first := bytes.IndexByte(tail, '\n')
		if first < 0 {
			return contextusage.Counts{}
		}
		tail = tail[first+1:]
	}
	// Ignore an unfinished write at EOF. An info-less token_count only updates
	// rate limits and can be skipped, but a compaction invalidates old usage.
	for end := bytes.LastIndexByte(tail, '\n'); end >= 0; {
		start := bytes.LastIndexByte(tail[:end], '\n')
		line := tail[start+1 : end]
		end = start
		if !bytes.Contains(line, []byte("token_count")) && !bytes.Contains(line, []byte("compacted")) {
			continue
		}
		var row struct {
			Type    string `json:"type"`
			Payload struct {
				Type string          `json:"type"`
				Info json.RawMessage `json:"info"`
			} `json:"payload"`
		}
		if json.Unmarshal(line, &row) != nil {
			continue
		}
		if row.Type == "compacted" || row.Type == "event_msg" && row.Payload.Type == "context_compacted" {
			break
		}
		if row.Type == "event_msg" && row.Payload.Type == "token_count" {
			raw := row.Payload.Info
			if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
				continue
			}
			var info struct {
				Limit json.RawMessage `json:"model_context_window"`
				Last  json.RawMessage `json:"last_token_usage"`
			}
			if json.Unmarshal(raw, &info) != nil {
				return contextusage.Counts{}
			}
			var limit *int64
			_ = json.Unmarshal(info.Limit, &limit)
			var last struct {
				Total *int64 `json:"total_tokens"`
			}
			if json.Unmarshal(info.Last, &last) != nil {
				return contextusage.New(nil, limit)
			}
			return contextusage.New(last.Total, limit)
		}
	}
	return contextusage.Counts{}
}

func (r *phReader) claudeConversationContext(home, pane, session string, started, now time.Time) contextusage.Counts {
	if home == "" || started.IsZero() || !phSafeID.MatchString(pane) {
		return contextusage.Counts{}
	}
	directory := filepath.Join(home, ".local", "share", "relay", "claude-status")
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 || phStatUID(info) != r.uid {
		return contextusage.Counts{}
	}
	result := contextusage.Counts{}
	phCatch(func() {
		data, info := r.privateFile(filepath.Join(directory, pane+".json"), 65536)
		if info.Mode().Perm()&0077 != 0 || len(data) > 65536 {
			return
		}
		var status struct {
			Pane     string              `json:"pane_id"`
			Session  string              `json:"session_id"`
			Captured time.Time           `json:"captured_at"`
			Usage    contextusage.Counts `json:"context_usage"`
		}
		if json.Unmarshal(data, &status) == nil && status.Pane == pane && status.Session == session &&
			!status.Captured.After(now) && !status.Captured.Before(started) {
			result = contextusage.New(status.Usage.Used, status.Usage.Limit)
		}
	}, phOSError, phUnbound)
	return result
}

func (r *phReader) readConversationContext(file *os.File, size int64, pane, provider, session string, pid int64) contextusage.Counts {
	switch provider {
	case "claude":
		var started time.Time
		phCatch(func() {
			epoch := r.epoch(pid)
			if epoch > 0 {
				started = time.Unix(0, int64(epoch*1e9))
			}
		}, phOSError, phUnbound, phValueError, phRuntimeError)
		return r.claudeConversationContext(phHome(), pane, session, started, time.Now())
	case "codex":
		start := max(int64(0), size-conversationContextTail)
		tail, err := io.ReadAll(io.NewSectionReader(file, start, size-start))
		if err == nil && int64(len(tail)) == size-start {
			return codexConversationContext(tail, start != 0)
		}
	}
	return contextusage.Counts{}
}

func (r *phReader) conversationContext(pane string, root int64, binary string) *pyObject {
	if root == 0 {
		root = r.rootForPane(pane)
	}
	rootStart := r.identity(root)
	pid, provider := r.agent(root, binary, pane)
	start := r.identity(pid)
	verified := r.binding(binary, pane, pid, provider)
	var nativeStart any
	if !conversationBound(verified) {
		nativeStart = r.nativeProcessStart(binary, pane, pid, provider)
	}
	path, session := r.conversationPath(pid, provider, verified)
	file, info := conversationFile(path, r.uid)
	defer file.Close()
	source := conversationSource(info)
	counts := r.readConversationContext(file, info.Size(), pane, provider, session, pid)
	after := phMustStat(path, true)
	if conversationSource(after) != source || after.Size() < info.Size() {
		phRaise(phUnbound, "The context source changed during the read.")
	}
	r.recheckConversationProcess(root, rootStart, pid, start)
	r.recheckConversationTranscript(pid, provider, path, session, verified)
	if conversationBound(verified) {
		if !pyEqual(r.binding(binary, pane, pid, provider), verified) {
			phRaise(phUnbound, "Authenticated binding changed during the context read.")
		}
		start = "kernel:" + pyStr(phGet(phIndex(verified, "producer"), "process_start", nil))
	} else if nativeStart != nil {
		if !pyEqual(r.nativeProcessStart(binary, pane, pid, provider), nativeStart) {
			phRaise(phUnbound, "Original CLI process changed during the context read.")
		}
		start = "kernel:" + pyStr(nativeStart)
	}
	usage := newPyObject()
	if counts.Used != nil {
		usage.Set("used_tokens", *counts.Used)
	}
	if counts.Limit != nil {
		usage.Set("limit_tokens", *counts.Limit)
	}
	return pyObj("version", int64(1), "binding", pyObj("pane_id", pane, "provider", provider,
		"process_id", pid, "process_start", start, "session_id", session, "source_identity", source),
		"context_usage", usage)
}
