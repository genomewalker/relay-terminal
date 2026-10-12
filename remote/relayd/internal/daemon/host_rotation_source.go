package daemon

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
)

const (
	rotationSourceFileLimit  = 64 << 20
	rotationSourceLineLimit  = 2 << 20
	rotationSourceTextLimit  = 4 << 20
	rotationSourceChunkLimit = 64 << 10
	rotationSourceMaxChunks  = 128
)

// This is an observed completed-turn watermark, never a model-generated value.
// The caller must still fence ledger ownership/turn_seq before and after drafting.
type hostRotationSourceBoundary struct {
	TurnID            string
	TurnSeq           uint64
	TranscriptMtimeMS int64
	TranscriptBytes   int64
}

type hostRotationSource struct {
	Enrollment       hostRotationEnrollment
	Boundary         hostRotationSourceBoundary
	BindingRevision  string
	TranscriptSHA256 string
	EvidenceSHA256   string
	Chunks           []string
	Messages         int
	info             os.FileInfo
}

type rotationSourceMessage struct {
	Role string
	Text string
}

type rotationSourcePart struct {
	Message int    `json:"message"`
	Role    string `json:"role"`
	Part    int    `json:"part"`
	Parts   int    `json:"parts"`
	Text    string `json:"text"`
}

// No file path, tool output, hidden reasoning or model instruction is accepted
// from an RPC request. Selection starts at the verified native association.
func collectHostRotationSource(ctx context.Context, e hostRotationEnrollment, boundary hostRotationSourceBoundary) (hostRotationSource, error) {
	var empty hostRotationSource
	if boundary.TurnSeq == 0 || boundary.TranscriptMtimeMS <= 0 || boundary.TranscriptBytes <= 0 || ctx.Err() != nil {
		return empty, errors.New("completed transcript boundary unavailable")
	}
	before, err := readHostRotationEnrollmentBinding(e)
	if err != nil {
		return empty, err
	}
	if before.Revision == "" || before.SessionID != e.SessionID ||
		before.Producer.Provider != e.Client || before.Producer.ProcessID != e.AgentPID ||
		before.Producer.ProcessStart != e.AgentStart {
		return empty, errors.New("capsule source binding unavailable")
	}
	source, err := readHostRotationSource(ctx, e, boundary, before)
	if err != nil {
		return empty, err
	}
	after, err := readHostRotationEnrollmentBinding(e)
	if err != nil || after.Revision != before.Revision || after.TranscriptPath != before.TranscriptPath ||
		after.SessionID != before.SessionID || after.Producer != before.Producer {
		return empty, errors.New("capsule source binding changed")
	}
	if ctx.Err() != nil {
		return empty, ctx.Err()
	}
	return source, nil
}

// A full reread also detects same-size edits with a restored modification time.
// Call this after a draft returns and before constructing a ledger capsule.
func revalidateHostRotationSource(ctx context.Context, source hostRotationSource) error {
	current, err := collectHostRotationSource(ctx, source.Enrollment, source.Boundary)
	if err != nil {
		return err
	}
	if current.BindingRevision != source.BindingRevision ||
		current.TranscriptSHA256 != source.TranscriptSHA256 ||
		current.EvidenceSHA256 != source.EvidenceSHA256 || !os.SameFile(source.info, current.info) {
		return errors.New("capsule source changed")
	}
	return nil
}

// Resolve the actual provider namespace, then reject links below it. This also
// supports the host's explicit CODEX_HOME without accepting arbitrary paths
// merely because they contain a ".claude" or ".codex" component.
func rotationSourcePath(path, provider string) (string, error) {
	if provider != "claude" && provider != "codex" {
		return "", errors.New("unsupported source provider")
	}
	logicalRoot := ""
	if provider == "codex" {
		logicalRoot = os.Getenv("CODEX_HOME")
	}
	if logicalRoot == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", errors.New("source home unavailable")
		}
		logicalRoot = filepath.Join(home, "."+provider)
	}
	if !filepath.IsAbs(logicalRoot) || filepath.Clean(logicalRoot) != logicalRoot ||
		len(logicalRoot) > 4096 || strings.ContainsRune(logicalRoot, 0) {
		return "", errors.New("invalid source namespace")
	}
	root, err := filepath.EvalSymlinks(logicalRoot)
	if err != nil {
		return "", errors.New("source namespace unavailable")
	}
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return "", errors.New("invalid source path")
	}
	// Canonicalize only the known home prefix. Child links are never followed.
	relative, err := filepath.Rel(logicalRoot, path)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		relative, err = filepath.Rel(root, path)
	}
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", errors.New("source outside provider namespace")
	}
	pieces := strings.Split(relative, string(filepath.Separator))
	if (provider == "codex" && pieces[0] != "sessions") || (provider == "claude" && pieces[0] != "projects") ||
		!strings.HasSuffix(relative, ".jsonl") {
		return "", errors.New("unsupported source location")
	}
	current := root
	for i := -1; i < len(pieces); i++ {
		if i >= 0 {
			current = filepath.Join(current, pieces[i])
		}
		info, err := os.Lstat(current)
		if err != nil {
			return "", errors.New("source path unavailable")
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != os.Getuid() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 ||
			(i < len(pieces)-1 && !info.IsDir()) ||
			(i == len(pieces)-1 && (!info.Mode().IsRegular() || stat.Nlink != 1)) {
			return "", errors.New("unsafe source path")
		}
	}
	return current, nil
}

func sameRotationSourceFile(a, b os.FileInfo) bool {
	return a != nil && b != nil && os.SameFile(a, b) && a.Size() == b.Size() &&
		a.ModTime().Equal(b.ModTime()) && a.Mode() == b.Mode()
}

func readHostRotationSource(ctx context.Context, e hostRotationEnrollment, boundary hostRotationSourceBoundary, binding AgentBindingRecord) (hostRotationSource, error) {
	var empty hostRotationSource
	path, err := rotationSourcePath(binding.TranscriptPath, e.Client)
	if err != nil {
		return empty, err
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return empty, errors.New("source open unavailable")
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	before, err := file.Stat()
	current, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !sameRotationSourceFile(before, current) ||
		before.Size() <= 0 || before.Size() > rotationSourceFileLimit || before.Size() != boundary.TranscriptBytes ||
		before.ModTime().UnixMilli() != boundary.TranscriptMtimeMS {
		return empty, errors.New("source is stale or exceeds file limit")
	}
	hash := sha256.New()
	messages, err := parseRotationSource(ctx, io.TeeReader(io.LimitReader(file, rotationSourceFileLimit+1), hash), e.Client, e.SessionID, e.CWD)
	if err != nil {
		return empty, err
	}
	after, err := file.Stat()
	finalPath, pathErr := rotationSourcePath(binding.TranscriptPath, e.Client)
	final, finalErr := os.Lstat(path)
	if err != nil || pathErr != nil || finalErr != nil || finalPath != path ||
		!sameRotationSourceFile(before, after) || !sameRotationSourceFile(before, final) {
		return empty, errors.New("source changed during collection")
	}
	chunks, digest, err := chunkRotationSource(messages)
	if err != nil {
		return empty, err
	}
	return hostRotationSource{Enrollment: e, Boundary: boundary, BindingRevision: binding.Revision,
		TranscriptSHA256: hex.EncodeToString(hash.Sum(nil)), EvidenceSHA256: digest,
		Chunks: chunks, Messages: len(messages), info: before}, nil
}

type rotationSourceRow struct {
	Type      string          `json:"type"`
	SessionID string          `json:"sessionId"`
	CWD       string          `json:"cwd"`
	UUID      string          `json:"uuid"`
	Parent    json.RawMessage `json:"parentUuid"`
	Sidechain bool            `json:"isSidechain"`
	Meta      bool            `json:"isMeta"`
	Payload   json.RawMessage `json:"payload"`
	Message   json.RawMessage `json:"message"`
}

type rotationClaudeNode struct {
	parent  string
	message rotationSourceMessage
}

// Only the explicit public message schemas below can contribute evidence.
// Unknown envelope kinds are ignored; malformed JSON and ambiguous identities
// fail closed. Claude follows the latest root branch's UUID ancestry.
func parseRotationSource(ctx context.Context, reader io.Reader, provider, session, cwd string) ([]rotationSourceMessage, error) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), rotationSourceLineLimit)
	messages := []rotationSourceMessage{}
	nodes := map[string]rotationClaudeNode{}
	last := ""
	identified := false
	textBytes, records := 0, 0
	codex := rotationCodexPublicSource{session: session}
	for scanner.Scan() {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		records++
		if records > 200000 {
			return nil, errors.New("source record limit exceeded")
		}
		line := scanner.Bytes()
		if !utf8.Valid(line) || !rotationSourceJSONUnambiguous(line) {
			return nil, errors.New("invalid source JSON")
		}
		var row rotationSourceRow
		if json.Unmarshal(line, &row) != nil {
			return nil, errors.New("invalid source record")
		}
		if provider == "codex" {
			switch row.Type {
			case "session_meta":
				var meta struct {
					ID           string          `json:"id"`
					CWD          string          `json:"cwd"`
					ThreadSource string          `json:"thread_source"`
					Source       json.RawMessage `json:"source"`
				}
				if identified || json.Unmarshal(row.Payload, &meta) != nil || meta.ID != session || meta.CWD != cwd ||
					(meta.ThreadSource != "" && meta.ThreadSource != "user") ||
					(meta.ThreadSource == "" && string(meta.Source) != `"cli"`) {
					return nil, errors.New("source session identity mismatch")
				}
				identified = true
				codex.identified = true
			case "response_item":
				if !identified {
					return nil, errors.New("source identity must precede messages")
				}
				if err := codex.response(row.Payload); err != nil {
					return nil, err
				}
			case "event_msg":
				if err := codex.event(row.Payload); err != nil {
					return nil, err
				}
			case "compacted":
				// Historical public messages remain evidence; replacement_history
				// is deliberately excluded because it can contain hidden fields.
			}
		} else if provider == "claude" {
			if row.Type != "user" && row.Type != "assistant" {
				continue
			}
			if row.Sidechain {
				continue
			}
			if row.SessionID != session || row.CWD != cwd || row.UUID == "" || len(row.UUID) > 128 || len(row.Parent) == 0 {
				return nil, errors.New("source session identity mismatch")
			}
			if _, exists := nodes[row.UUID]; exists {
				return nil, errors.New("duplicate source message identity")
			}
			var parent string
			if string(row.Parent) != "null" && json.Unmarshal(row.Parent, &parent) != nil {
				return nil, errors.New("invalid source parent")
			}
			var message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			}
			if json.Unmarshal(row.Message, &message) != nil || message.Role != row.Type {
				return nil, errors.New("invalid public message")
			}
			text := ""
			if !row.Meta {
				var err error
				text, err = rotationPublicText(message.Content, row.Type, true)
				if err != nil {
					return nil, err
				}
			}
			nodes[row.UUID] = rotationClaudeNode{parent, rotationSourceMessage{row.Type, text}}
			last, identified = row.UUID, true
			textBytes += len(text)
		} else {
			return nil, errors.New("unsupported source provider")
		}
		if textBytes > rotationSourceTextLimit {
			return nil, errors.New("source text limit exceeded")
		}
	}
	if scanner.Err() != nil {
		return nil, errors.New("source line limit or read failure")
	}
	if provider == "codex" {
		messages = codex.messages()
	}
	if provider == "claude" {
		seen := map[string]bool{}
		for last != "" {
			node, ok := nodes[last]
			if !ok || seen[last] {
				return nil, errors.New("source ancestry incomplete or cyclic")
			}
			seen[last] = true
			if node.message.Text != "" {
				messages = append(messages, node.message)
			}
			last = node.parent
		}
		for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
			messages[i], messages[j] = messages[j], messages[i]
		}
	}
	users, assistants := 0, 0
	for _, m := range messages {
		if m.Role == "user" {
			users++
		} else {
			assistants++
		}
	}
	if !identified || users == 0 || assistants == 0 {
		return nil, errors.New("complete public conversation unavailable")
	}
	return messages, nil
}

func rotationPublicText(raw json.RawMessage, role string, claude bool) (string, error) {
	if claude && role == "user" && len(raw) > 0 && raw[0] == '"' {
		var text string
		if json.Unmarshal(raw, &text) != nil {
			return "", errors.New("invalid public text")
		}
		return text, nil
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) != nil {
		return "", errors.New("unsupported public content")
	}
	text := []string{}
	for _, block := range blocks {
		allowed := claude && block.Type == "text" || !claude && (role == "user" && block.Type == "input_text" || role == "assistant" && block.Type == "output_text")
		if allowed && block.Text != "" {
			text = append(text, block.Text)
		}
	}
	return strings.Join(text, "\n"), nil
}

// Duplicate JSON keys could turn an analysis channel into a public channel
// depending on decoder behavior. Reject them recursively with a depth bound.
func rotationSourceJSONUnambiguous(data []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value func(int) bool
	value = func(depth int) bool {
		if depth > 64 {
			return false
		}
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		d, ok := token.(json.Delim)
		if !ok {
			return true
		}
		if d != '{' && d != '[' {
			return false
		}
		keys := map[string]bool{}
		for decoder.More() {
			if d == '{' {
				key, err := decoder.Token()
				s, ok := key.(string)
				if err != nil || !ok || keys[s] {
					return false
				}
				keys[s] = true
			}
			if !value(depth + 1) {
				return false
			}
		}
		end, err := decoder.Token()
		return err == nil && (d == '{' && end == json.Delim('}') || d == '[' && end == json.Delim(']'))
	}
	if !value(0) {
		return false
	}
	_, err := decoder.Token()
	return errors.Is(err, io.EOF)
}

// Each chunk is independently valid bounded JSON. Long messages are split at
// UTF-8 boundaries with explicit part numbers; no selected text is discarded.
// The caller must finish every chunk before accepting an aggregate handoff.
func chunkRotationSource(messages []rotationSourceMessage) ([]string, string, error) {
	chunks := []string{}
	batch := []rotationSourcePart{}
	total := 0
	encode := func(parts []rotationSourcePart) []byte {
		data, _ := json.Marshal(struct {
			Version  int                  `json:"v"`
			Messages []rotationSourcePart `json:"messages"`
		}{1, parts})
		return data
	}
	for index, message := range messages {
		total += len(message.Text)
		if total > rotationSourceTextLimit || !utf8.ValidString(message.Text) {
			return nil, "", errors.New("source text limit or encoding invalid")
		}
		pieces := []string{}
		for remaining := message.Text; remaining != ""; {
			n := len(remaining)
			if n > 8192 {
				n = 8192
				for !utf8.RuneStart(remaining[n]) {
					n--
				}
			}
			pieces = append(pieces, remaining[:n])
			remaining = remaining[n:]
		}
		for part, piece := range pieces {
			entry := rotationSourcePart{index + 1, message.Role, part + 1, len(pieces), piece}
			next := append(batch, entry)
			if len(encode(next)) > rotationSourceChunkLimit {
				chunks = append(chunks, string(encode(batch)))
				batch = []rotationSourcePart{entry}
			} else {
				batch = next
			}
			if len(chunks) >= rotationSourceMaxChunks {
				return nil, "", errors.New("source chunk limit exceeded")
			}
		}
	}
	if len(batch) > 0 {
		chunks = append(chunks, string(encode(batch)))
	}
	if len(chunks) == 0 {
		return nil, "", errors.New("empty source evidence")
	}
	data, _ := json.Marshal(chunks)
	digest := sha256.Sum256(data)
	return chunks, hex.EncodeToString(digest[:]), nil
}
