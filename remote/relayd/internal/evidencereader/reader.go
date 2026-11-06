// Package evidencereader is the only MCP server a dedicated research worker
// gets (P2). It serves a fixed allowlist of evidence files, bound to the
// research contract hash, over stdio JSON-RPC. It offers exactly three
// read-only tools (list, read, search) and has no write, shell, network or
// path argument: callers name evidence only by allowlisted ID.
//
// Binding, all checked before the server answers anything:
//   - the allowlist file's bytes hash to --allowlist-sha256 (no swapped file);
//   - its contract_sha256 equals --contract-sha256 (the research contract);
//   - every entry is a relative path that stays under the root after symlink
//     resolution, is a regular file within the size limit, and hashes to its
//     listed sha256.
//
// Each read re-hashes the file, so evidence changed after start-up is refused
// rather than served.
package evidencereader

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"unicode/utf8"
)

const (
	ProtocolVersion  = "2025-06-18"
	MaxAllowlistSize = 1 << 20
	MaxEvidenceSize  = 8 << 20
	MaxEntries       = 4096
	MaxReadBytes     = 64 << 10
	MaxSearchResults = 50
	MaxLine          = 1 << 20
)

var (
	sha256Hex  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	evidenceID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
)

// ToolNames are the reader's tools; the worker planner prefixes them with
// mcp__evidence__.
var ToolNames = []string{"list", "read", "search"}

type allowlistFile struct {
	Version        int     `json:"version"`
	ContractSHA256 string  `json:"contract_sha256"`
	Root           string  `json:"root"`
	Evidence       []entry `json:"evidence"`
}

type entry struct {
	ID     string `json:"id"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type item struct {
	entry
	real string // resolved absolute path under the real root
	size int64
}

type Reader struct {
	contract string
	order    []string
	items    map[string]item
}

// Open loads and verifies the allowlist. Any failure refuses the whole reader.
func Open(allowlistPath, allowlistSHA256, contractSHA256 string) (*Reader, error) {
	if !sha256Hex.MatchString(allowlistSHA256) || !sha256Hex.MatchString(contractSHA256) {
		return nil, errors.New("allowlist and contract hashes must be 64 lowercase hex")
	}
	if !filepath.IsAbs(allowlistPath) {
		return nil, errors.New("allowlist path must be absolute")
	}
	raw, err := readRegular(allowlistPath, MaxAllowlistSize)
	if err != nil {
		return nil, fmt.Errorf("allowlist: %w", err)
	}
	if digest(raw) != allowlistSHA256 {
		return nil, errors.New("allowlist bytes do not match --allowlist-sha256")
	}
	var list allowlistFile
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&list); err != nil {
		return nil, fmt.Errorf("allowlist is not valid: %w", err)
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("allowlist has trailing data")
	}
	if list.Version != 1 {
		return nil, errors.New("allowlist version must be 1")
	}
	if list.ContractSHA256 != contractSHA256 {
		return nil, errors.New("allowlist is bound to a different contract")
	}
	if !filepath.IsAbs(list.Root) || filepath.Clean(list.Root) != list.Root {
		return nil, errors.New("evidence root must be a clean absolute path")
	}
	root, err := filepath.EvalSymlinks(list.Root)
	if err != nil {
		return nil, fmt.Errorf("evidence root: %w", err)
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return nil, errors.New("evidence root is not a directory")
	}
	if len(list.Evidence) == 0 || len(list.Evidence) > MaxEntries {
		return nil, fmt.Errorf("allowlist needs 1-%d entries", MaxEntries)
	}
	r := &Reader{contract: contractSHA256, items: map[string]item{}}
	for _, e := range list.Evidence {
		if !evidenceID.MatchString(e.ID) {
			return nil, fmt.Errorf("evidence id %q is not valid", e.ID)
		}
		if _, dup := r.items[e.ID]; dup {
			return nil, fmt.Errorf("evidence id %q is listed twice", e.ID)
		}
		if !sha256Hex.MatchString(e.SHA256) {
			return nil, fmt.Errorf("%s: sha256 must be 64 lowercase hex", e.ID)
		}
		real, err := resolveUnder(root, e.Path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", e.ID, err)
		}
		content, err := readRegular(real, MaxEvidenceSize)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", e.ID, err)
		}
		if digest(content) != e.SHA256 {
			return nil, fmt.Errorf("%s: content does not match its sha256", e.ID)
		}
		r.items[e.ID] = item{entry: e, real: real, size: int64(len(content))}
		r.order = append(r.order, e.ID)
	}
	return r, nil
}

// resolveUnder accepts only a clean relative path whose fully resolved target
// stays inside root.
func resolveUnder(root, path string) (string, error) {
	if path == "" || filepath.IsAbs(path) || filepath.Clean(path) != path || path == "." ||
		path == ".." || strings.HasPrefix(path, "../") || strings.Contains(path, "\x00") {
		return "", errors.New("path must be a clean relative path inside the root")
	}
	real, err := filepath.EvalSymlinks(filepath.Join(root, path))
	if err != nil {
		return "", errors.New("path does not resolve")
	}
	relative, err := filepath.Rel(root, real)
	if err != nil || relative == ".." || strings.HasPrefix(relative, "../") || filepath.IsAbs(relative) {
		return "", errors.New("path escapes the evidence root")
	}
	return real, nil
}

// readRegular reads a regular, non-symlink file of at most limit bytes.
func readRegular(path string, limit int64) ([]byte, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, errors.New("cannot open as a regular file")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}
	if info.Size() > limit {
		return nil, fmt.Errorf("larger than %d bytes", limit)
	}
	content, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(content)) > limit {
		return nil, errors.New("cannot read within the size limit")
	}
	return content, nil
}

func digest(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

// current returns an item's content only while it still matches its hash.
func (r *Reader) current(id string) ([]byte, error) {
	it, ok := r.items[id]
	if !ok {
		return nil, fmt.Errorf("evidence id %q is not in the allowlist", id)
	}
	content, err := readRegular(it.real, MaxEvidenceSize)
	if err != nil || digest(content) != it.SHA256 {
		return nil, fmt.Errorf("evidence %q changed since the allowlist was verified; refused", id)
	}
	return content, nil
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func toolsList() []any {
	object := func(properties map[string]any, required ...string) map[string]any {
		return map[string]any{"type": "object", "properties": properties, "required": append([]string{}, required...), "additionalProperties": false}
	}
	id := map[string]any{"type": "string", "pattern": evidenceID.String()}
	return []any{
		map[string]any{"name": "list", "description": "List the allowlisted evidence IDs with size and sha256. Read-only.", "inputSchema": object(map[string]any{}), "annotations": map[string]any{"readOnlyHint": true}},
		map[string]any{"name": "read", "description": "Read one allowlisted evidence item by ID (UTF-8 text, at most 64 KiB per call; use offset to continue). Refused if the file changed since verification.",
			"inputSchema": object(map[string]any{"id": id, "offset": map[string]any{"type": "integer", "minimum": 0}, "limit": map[string]any{"type": "integer", "minimum": 1, "maximum": MaxReadBytes}}, "id"), "annotations": map[string]any{"readOnlyHint": true}},
		map[string]any{"name": "search", "description": "Case-insensitive literal search in allowlisted evidence. Returns ID, line number and line. Read-only.",
			"inputSchema": object(map[string]any{"query": map[string]any{"type": "string", "minLength": 1, "maxLength": 256}, "ids": map[string]any{"type": "array", "maxItems": 64, "items": id}, "max_results": map[string]any{"type": "integer", "minimum": 1, "maximum": MaxSearchResults}}, "query"), "annotations": map[string]any{"readOnlyHint": true}},
	}
}

func strictArgs(raw json.RawMessage, dst any) bool {
	if len(raw) == 0 {
		raw = []byte("{}")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return false
	}
	for _, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return false
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	return decoder.Decode(dst) == nil
}

func text(value any, isError bool) map[string]any {
	encoded, _ := json.Marshal(value)
	if s, ok := value.(string); ok {
		encoded = []byte(s)
	}
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": string(encoded)}}, "isError": isError}
}

func (r *Reader) call(name string, arguments json.RawMessage) (any, *rpcError) {
	invalid := &rpcError{Code: -32602, Message: "invalid arguments for " + name}
	switch name {
	case "list":
		var none struct{}
		if !strictArgs(arguments, &none) {
			return nil, invalid
		}
		items := make([]map[string]any, 0, len(r.order))
		for _, id := range r.order {
			it := r.items[id]
			items = append(items, map[string]any{"id": id, "size": it.size, "sha256": it.SHA256})
		}
		return text(map[string]any{"contract_sha256": r.contract, "evidence": items}, false), nil
	case "read":
		var args struct {
			ID     string `json:"id"`
			Offset *int   `json:"offset"`
			Limit  *int   `json:"limit"`
		}
		if !strictArgs(arguments, &args) || args.ID == "" || (args.Offset != nil && *args.Offset < 0) || (args.Limit != nil && (*args.Limit < 1 || *args.Limit > MaxReadBytes)) {
			return nil, invalid
		}
		content, err := r.current(args.ID)
		if err != nil {
			return text(err.Error(), true), nil
		}
		if !utf8.Valid(content) {
			return text(fmt.Sprintf("evidence %q is not UTF-8 text", args.ID), true), nil
		}
		offset, limit := 0, MaxReadBytes
		if args.Offset != nil {
			offset = *args.Offset
		}
		if args.Limit != nil {
			limit = *args.Limit
		}
		if offset > len(content) {
			offset = len(content)
		}
		end := min(offset+limit, len(content))
		for end < len(content) && end > offset && !utf8.RuneStart(content[end]) {
			end--
		}
		if end == offset && offset < len(content) {
			// limit is smaller than this rune; return the whole rune so the reader advances.
			_, size := utf8.DecodeRune(content[offset:])
			end = offset + size
		}
		return text(map[string]any{"id": args.ID, "sha256": r.items[args.ID].SHA256, "offset": offset, "next_offset": end, "eof": end == len(content), "text": string(content[offset:end])}, false), nil
	case "search":
		var args struct {
			Query      string   `json:"query"`
			IDs        []string `json:"ids"`
			MaxResults *int     `json:"max_results"`
		}
		if !strictArgs(arguments, &args) || args.Query == "" || len(args.Query) > 256 || len(args.IDs) > 64 || (args.MaxResults != nil && (*args.MaxResults < 1 || *args.MaxResults > MaxSearchResults)) {
			return nil, invalid
		}
		ids := args.IDs
		if len(ids) == 0 {
			ids = r.order
		}
		for _, id := range ids {
			if _, ok := r.items[id]; !ok {
				return text(fmt.Sprintf("evidence id %q is not in the allowlist", id), true), nil
			}
		}
		limit := MaxSearchResults
		if args.MaxResults != nil {
			limit = *args.MaxResults
		}
		query := strings.ToLower(args.Query)
		matches := []map[string]any{}
		for _, id := range ids {
			content, err := r.current(id)
			if err != nil {
				return text(err.Error(), true), nil
			}
			for number, line := range strings.Split(string(content), "\n") {
				if strings.Contains(strings.ToLower(line), query) {
					if len(line) > 512 {
						line = line[:512]
					}
					matches = append(matches, map[string]any{"id": id, "line": number + 1, "text": line})
					if len(matches) == limit {
						return text(map[string]any{"matches": matches, "truncated": true}, false), nil
					}
				}
			}
		}
		return text(map[string]any{"matches": matches, "truncated": false}, false), nil
	}
	return nil, &rpcError{Code: -32602, Message: "unknown tool; this reader offers only list, read and search"}
}

// Handle answers one JSON-RPC message; notifications return nil.
func (r *Reader) Handle(line []byte) []byte {
	var message struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}
	if json.Unmarshal(line, &message) != nil {
		encoded, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": nil, "error": rpcError{Code: -32700, Message: "parse error"}})
		return encoded
	}
	if len(message.ID) == 0 || bytes.Equal(message.ID, []byte("null")) {
		return nil
	}
	reply := map[string]any{"jsonrpc": "2.0", "id": message.ID}
	var result any
	var failure *rpcError
	switch message.Method {
	case "initialize":
		result = map[string]any{"protocolVersion": ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "relay-evidence-reader", "version": "1"}}
	case "ping":
		result = map[string]any{}
	case "tools/list":
		result = map[string]any{"tools": toolsList()}
	case "tools/call":
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(message.Params, &params) != nil {
			failure = &rpcError{Code: -32602, Message: "invalid tool call"}
		} else {
			result, failure = r.call(params.Name, params.Arguments)
		}
	default:
		failure = &rpcError{Code: -32601, Message: "method not supported"}
	}
	if failure != nil {
		reply["error"] = failure
	} else {
		reply["result"] = result
	}
	encoded, _ := json.Marshal(reply)
	return encoded
}

// Serve answers newline-delimited JSON-RPC until in closes.
func (r *Reader) Serve(in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64<<10), MaxLine)
	writer := bufio.NewWriter(out)
	for scanner.Scan() {
		if reply := r.Handle(scanner.Bytes()); reply != nil {
			if _, err := writer.Write(append(reply, '\n')); err != nil {
				return err
			}
			if err := writer.Flush(); err != nil {
				return err
			}
		}
	}
	return scanner.Err()
}

// IDs returns the allowlisted IDs in allowlist order.
func (r *Reader) IDs() []string {
	return append([]string{}, r.order...)
}
