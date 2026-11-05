package daemon

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	conversationMaxScan   = 64 << 20
	conversationMaxLine   = 16 << 20
	conversationMaxBody   = 128 << 10
	conversationMaxOutput = 512 << 10
)

var conversationJSON = pyEncodeOptions{itemSep: ", ", keySep: ": "}
var conversationCompactJSON = pyEncodeOptions{itemSep: ",", keySep: ":"}

func conversationBound(value *pyObject) bool { return value != nil && value.Len() > 0 }

func conversationString(v any) string { text, _ := v.(string); return text }
func conversationPrefix(text string, count int) string {
	if count < 0 {
		count = 0
	}
	runes := []rune(text)
	if len(runes) > count {
		return string(runes[:count])
	}
	return text
}

type conversationTool struct{ name, status, summary string }

func conversationTextBlocks(content any, depth int) (string, []conversationTool) {
	if depth > 1000 {
		phRaise(phValueError, "Conversation nesting exceeds its limit.")
	}
	if text, ok := content.(string); ok {
		return text, nil
	}
	var text []string
	var tools []conversationTool
	if blocks, ok := content.(*pyList); ok {
		for i, raw := range blocks.items {
			if i >= 256 {
				break
			}
			block, ok := raw.(*pyObject)
			if !ok {
				continue
			}
			switch block.Get("type") {
			case "text", "input_text", "output_text":
				text = append(text, conversationString(block.Get("text")))
			case "tool_use":
				tools = append(tools, conversationTool{conversationString(block.Get("name")), "requested", conversationPrefix(string(pyEncode(block.GetOr("input", newPyObject()), conversationJSON)), 8192)})
			case "tool_result":
				body, _ := conversationTextBlocks(block.Get("content"), depth+1)
				status := "completed"
				if pyTruthy(block.Get("is_error")) {
					status = "failed"
				}
				tools = append(tools, conversationTool{conversationString(block.Get("tool_use_id")), status, conversationPrefix(body, 32768)})
			case "image", "input_image":
				text = append(text, "[Image attached in provider transcript]")
			}
		}
	}
	return strings.Join(text, "\n"), tools
}

func conversationEmbeddedImage(raw any) (string, string) {
	block, ok := raw.(*pyObject)
	if !ok || !phContains([]string{"image", "input_image"}, conversationString(block.Get("type"))) {
		return "", ""
	}
	source := block.GetOr("source", newPyObject())
	mime, encoded := "", ""
	if object, ok := source.(*pyObject); ok && pyEqual(object.Get("type"), "base64") {
		mime, encoded = conversationString(object.Get("media_type")), conversationString(object.Get("data"))
	} else {
		rawURL := block.GetOr("image_url", "")
		if object, ok := rawURL.(*pyObject); ok {
			rawURL = object.GetOr("url", "")
		}
		if url, ok := rawURL.(string); ok && strings.HasPrefix(url, "data:") && strings.Contains(url, ";base64,") {
			mime, encoded, _ = strings.Cut(url[5:], ";base64,")
		}
	}
	if !phContains([]string{"image/png", "image/jpeg", "image/gif", "image/webp"}, mime) || encoded == "" || pyLen(encoded) > 12<<20 {
		return "", ""
	}
	return mime, encoded
}

func conversationImageAttachments(content any, offset int64) *pyList {
	images := pyListOf()
	blocks, ok := content.(*pyList)
	if !ok {
		return images
	}
	for index, block := range blocks.items {
		if index >= 256 {
			break
		}
		mime, encoded := conversationEmbeddedImage(block)
		if encoded == "" {
			continue
		}
		digest := sha256.Sum256([]byte(encoded))
		images.items = append(images.items, pyObj("mime", mime, "offset", offset, "index", int64(index), "digest", hex.EncodeToString(digest[:])))
		if len(images.items) == 16 {
			break
		}
	}
	return images
}

func parseConversationRow(row *pyObject, kind, session string, offset int64, toolNames *pyObject) *pyList {
	result := pyListOf()
	stable := conversationString(row.Get("uuid"))
	if stable == "" {
		stable = pyStr(offset)
	}
	role, text := "", ""
	var tools []conversationTool
	var content any
	if kind == "claude" {
		if !pyEqual(row.Get("sessionId"), session) || pyTruthy(row.Get("isSidechain")) || !phContains([]string{"user", "assistant"}, conversationString(row.Get("type"))) {
			return result
		}
		message := row.Get("message")
		if !pyTruthy(message) {
			message = newPyObject()
		}
		content = phGet(message, "content", nil)
		if blocks, ok := content.(*pyList); ok {
			for i, raw := range blocks.items {
				if i >= 256 {
					break
				}
				block, ok := raw.(*pyObject)
				if !ok || !pyEqual(block.Get("type"), "tool_use") {
					continue
				}
				id, name := conversationString(block.Get("id")), conversationString(block.Get("name"))
				if id != "" && name != "" && len(id) <= 256 && len(name) <= 256 {
					toolNames.Set(id, name)
					for toolNames.Len() > 4096 {
						toolNames.Delete(toolNames.keys[0])
					}
				}
			}
		}
		role = conversationString(row.Get("type"))
		text, tools = conversationTextBlocks(content, 0)
		for i := range tools {
			if tools[i].status == "completed" || tools[i].status == "failed" {
				tools[i].name = conversationString(toolNames.GetOr(tools[i].name, "Tool result"))
			}
		}
	} else if pyEqual(row.Get("type"), "response_item") {
		payload, ok := row.GetOr("payload", newPyObject()).(*pyObject)
		if !ok {
			return result
		}
		if id := conversationString(payload.Get("id")); id != "" {
			stable = id
		}
		if pyEqual(payload.Get("type"), "message") && phContains([]string{"user", "assistant"}, conversationString(payload.Get("role"))) {
			role = conversationString(payload.Get("role"))
			text, tools = conversationTextBlocks(payload.Get("content"), 0)
		} else if phContains([]string{"function_call", "function_call_output"}, conversationString(payload.Get("type"))) {
			if id := conversationString(payload.Get("call_id")); id != "" {
				stable = id
			}
			stable += ":" + payload.Get("type").(string)
			name := conversationString(payload.Get("name"))
			if name == "" {
				name = "Tool result"
			}
			status := "requested"
			if pyEqual(payload.Get("type"), "function_call_output") {
				status = "completed"
			}
			tools = []conversationTool{{name, status, conversationPrefix(conversationString(payload.GetOr("output", payload.Get("arguments"))), 32768)}}
		}
	} else if pyEqual(row.Get("type"), "event_msg") {
		payload := row.GetOr("payload", newPyObject())
		if pyEqual(phGet(payload, "type", nil), "plan_update") {
			tools = []conversationTool{{"Plan", "updated", conversationPrefix(string(pyEncode(phGet(payload, "plan", pyListOf()), conversationJSON)), 8192)}}
		}
	}
	images := conversationImageAttachments(content, offset)
	if (text != "" || len(images.items) > 0) && role != "" && len(text) <= conversationMaxBody {
		if len(images.items) > 0 {
			text = phStrip(strings.Replace(text, "[Image attached in provider transcript]", "", len(images.items)))
		}
		result.items = append(result.items, pyObj("id", stable, "role", role, "text", text, "images", images, "revision", offset+1))
	}
	for index, tool := range tools {
		if index >= 64 {
			break
		}
		result.items = append(result.items, pyObj("id", stable+":tool:"+pyStr(int64(index)), "role", "tool", "text", tool.summary, "tool_name", tool.name, "tool_status", tool.status, "revision", offset+1))
	}
	return result
}

func (r *phReader) recheckConversationTranscript(pid int64, kind, path, session string, verified *pyObject) {
	if conversationBound(verified) && pyTruthy(verified.Get("transcript_path")) {
		if phResolve(phPath(verified.Get("transcript_path").(string)), false) != phResolve(path, false) || !pyEqual(r.metadata(path, kind), session) {
			phRaise(phUnbound, "Authenticated transcript session changed during the read; refresh.")
		}
		return
	}
	current, currentSession := r.transcript(pid, kind)
	if phResolve(current, false) != phResolve(path, false) || currentSession != session {
		phRaise(phUnbound, "The frontend changed its bound transcript during the read; refresh.")
	}
}

func conversationFile(path string, uid int) (*os.File, os.FileInfo) {
	file := phOpenNoFollow(path)
	info, err := file.Stat()
	if err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if phStatUID(info) != uid || info.Mode().Perm()&0022 != 0 || !info.Mode().IsRegular() {
		file.Close()
		phRaise(phUnbound, "Transcript ownership changed.")
	}
	return file, info
}
func conversationSource(info os.FileInfo) string {
	dev, ino := phStatDevIno(info)
	return fmt.Sprint(dev, ":", ino)
}
func (r *phReader) conversationPath(pid int64, kind string, verified *pyObject) (string, string) {
	if conversationBound(verified) && pyTruthy(verified.Get("transcript_path")) {
		path := phPath(verified.Get("transcript_path").(string))
		session := phIndex(verified, "session_id").(string)
		if !pyEqual(r.metadata(path, kind), session) {
			phRaise(phUnbound, "Authenticated transcript session changed.")
		}
		return path, session
	}
	path, session := r.transcript(pid, kind)
	if conversationBound(verified) && !pyEqual(verified.Get("session_id"), session) {
		phRaise(phUnbound, "Authenticated session differs from the open transcript.")
	}
	return path, session
}
func (r *phReader) recheckConversationProcess(root int64, rootStart string, pid int64, start string) {
	if r.identity(root) != rootStart || r.identity(pid) != start || !phContainsValue(r.ancestorsOf(pid, r.inventory()), root) {
		phRaise(phUnbound, "The bound process changed during the read.")
	}
}

func (r *phReader) conversationBindingOnly(pane string, root int64, binary string) *pyObject {
	if binary == "" {
		phRaise(phUnbound, "A kernel identity reader is required.")
	}
	if root == 0 {
		root = r.rootForPane(pane)
	}
	rootStart := r.identity(root)
	pid, kind := r.agent(root, binary, pane)
	start := r.identity(pid)
	verified := r.binding(binary, pane, pid, kind)
	proxy := ""
	if conversationBound(verified) {
		proxy = phStockProxyIdentity(verified)
	}
	kernel := phLoads(r.run([]string{binary, "agent-process-identity", pane, pyStr(pid), kind}, 5))
	kernelStart := phGet(kernel, "process_start", nil)
	if !phStrictInt(kernelStart) || pyLessEq(kernelStart, int64(0)) {
		phRaise(phUnbound, "Kernel process identity is unavailable.")
	}
	if proxy != "" && !pyTruthy(verified.Get("transcript_path")) {
		r.recheckConversationProcess(root, rootStart, pid, start)
		after := phLoads(r.run([]string{binary, "agent-process-identity", pane, pyStr(pid), kind}, 5))
		if !pyEqual(r.binding(binary, pane, pid, kind), verified) || !pyEqual(phGet(after, "process_start", nil), kernelStart) {
			phRaise(phUnbound, "The live stock proxy binding changed.")
		}
		return pyObj("version", int64(1), "binding", pyObj("pane_id", pane, "provider", kind, "process_id", pid, "process_start", "kernel:"+pyStr(kernelStart), "session_id", verified.Get("session_id"), "source_identity", proxy))
	}
	path, session := r.conversationPath(pid, kind, verified)
	file, info := conversationFile(path, r.uid)
	defer file.Close()
	if conversationSource(info) != conversationSource(phMustStat(path, true)) {
		phRaise(phUnbound, "Transcript identity changed.")
	}
	r.recheckConversationProcess(root, rootStart, pid, start)
	r.recheckConversationTranscript(pid, kind, path, session, verified)
	after := phLoads(r.run([]string{binary, "agent-process-identity", pane, pyStr(pid), kind}, 5))
	if !pyEqual(phGet(after, "process_start", nil), kernelStart) {
		phRaise(phUnbound, "Kernel process identity changed.")
	}
	if conversationBound(verified) && !pyEqual(r.binding(binary, pane, pid, kind), verified) {
		phRaise(phUnbound, "Authenticated binding changed.")
	}
	return pyObj("version", int64(1), "binding", pyObj("pane_id", pane, "provider", kind, "process_id", pid, "process_start", "kernel:"+pyStr(kernelStart), "session_id", session, "source_identity", conversationSource(info)))
}

// conversationReadLine implements bounded binary readline, including the case
// where an oversized record has to be discarded across several chunks.
func conversationReadLine(reader *bufio.Reader, limit int) []byte {
	var line []byte
	for len(line) < limit {
		first, err := reader.Peek(1)
		if len(first) == 0 {
			if err == io.EOF {
				return line
			}
			phRaiseOS(err)
		}
		buffered, _ := reader.Peek(reader.Buffered())
		if len(buffered) > limit-len(line) {
			buffered = buffered[:limit-len(line)]
		}
		if index := bytes.IndexByte(buffered, '\n'); index >= 0 {
			line = append(line, buffered[:index+1]...)
			reader.Discard(index + 1)
			return line
		}
		line = append(line, buffered...)
		reader.Discard(len(buffered))
	}
	return line
}

func conversationLineAt(file *os.File, offset int64, limit int) []byte {
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		phRaiseOS(err)
	}
	return conversationReadLine(bufio.NewReaderSize(file, 65536), limit)
}

func (r *phReader) conversationSnapshot(pane string, root int64, binary string, before *int64, expectedSource, expectedSession string) *pyObject {
	if root == 0 {
		root = r.rootForPane(pane)
	}
	rootStart := r.identity(root)
	pid, kind := r.agent(root, binary, pane)
	start := r.identity(pid)
	verified := r.binding(binary, pane, pid, kind)
	var nativeStart any
	if !conversationBound(verified) {
		nativeStart = r.nativeProcessStart(binary, pane, pid, kind)
	}
	path, session := r.conversationPath(pid, kind, verified)
	file, info := conversationFile(path, r.uid)
	defer file.Close()
	source := conversationSource(info)
	if expectedSource != "" && (source != expectedSource || session != expectedSession) {
		phRaise(phUnbound, "The history source changed; return to the latest conversation.")
	}
	end := info.Size()
	if before != nil && *before < end {
		end = *before
	}
	scanStart := end - conversationMaxScan
	if scanStart < 0 {
		scanStart = 0
	}
	// Read only the fixed scan window. Track consumed bytes rather than the
	// underlying buffered file position, keeping history revisions exact.
	reader := bufio.NewReaderSize(io.NewSectionReader(file, scanStart, end-scanStart), 65536)
	offset := scanStart
	discarding, omitted := false, false
	if scanStart > 0 {
		first := conversationReadLine(reader, conversationMaxLine+1)
		offset += int64(len(first))
		discarding = !bytes.HasSuffix(first, []byte{'\n'})
	}
	items := pyListOf()
	retained := 0
	toolNames := newPyObject()
	var nativeState *pyList
	var nativeOffset int64
	for offset < end {
		lineOffset := offset
		line := conversationReadLine(reader, conversationMaxLine+1)
		if len(line) == 0 {
			break
		}
		offset += int64(len(line))
		if len(line) > conversationMaxLine || discarding {
			discarding = !bytes.HasSuffix(line, []byte{'\n'})
			continue
		}
		if !bytes.HasSuffix(line, []byte{'\n'}) || offset > end {
			break
		}
		var decoded any
		if phCatch(func() { decoded = phLoadsBytes(line) }, phValueError) != nil {
			continue
		}
		row, ok := decoded.(*pyObject)
		if !ok {
			continue
		}
		if nativeStart != nil {
			if state := r.codexLifecycle(row); state != nil {
				nativeState = state
				nativeOffset = lineOffset
			}
		}
		parsed := parseConversationRow(row, kind, session, lineOffset, toolNames)
		for _, item := range parsed.items {
			items.items = append(items.items, item)
			retained += len(pyEncode(item, conversationJSON))
		}
		for retained > conversationMaxOutput-8192 || len(items.items) > 256 {
			revision := phGet(items.items[0], "revision", nil)
			for len(items.items) > 0 && pyEqual(phGet(items.items[0], "revision", nil), revision) {
				retained -= len(pyEncode(items.items[0], conversationJSON))
				items.items = items.items[1:]
			}
			omitted = true
		}
	}
	after := phMustStat(path, true)
	if conversationSource(after) != source || after.Size() < info.Size() {
		phRaise(phUnbound, "Transcript rotated during the read; refresh to resynchronize.")
	}
	r.recheckConversationProcess(root, rootStart, pid, start)
	r.recheckConversationTranscript(pid, kind, path, session, verified)
	var control any
	if conversationBound(verified) {
		if !pyEqual(r.binding(binary, pane, pid, kind), verified) {
			phRaise(phUnbound, "Authenticated binding changed during the read; refresh.")
		}
		start = "kernel:" + pyStr(phGet(phIndex(verified, "producer"), "process_start", nil))
		control = pyObj("lifecycle", verified.GetOr("lifecycle", "unknown"), "revision", verified.GetOr("revision", ""), "observed_at", verified.GetOr("observed_at", ""))
	} else if nativeStart != nil {
		if !pyEqual(r.nativeProcessStart(binary, pane, pid, kind), nativeStart) {
			phRaise(phUnbound, "Original CLI process changed during the read.")
		}
		start = "kernel:" + pyStr(nativeStart)
		if nativeState != nil {
			digest := sha256.Sum256([]byte(source + ":" + pyStr(nativeOffset) + ":" + pyStr(nativeStart)))
			control = pyObj("lifecycle", nativeState.items[0], "revision", hex.EncodeToString(digest[:]), "observed_at", nativeState.items[1])
		}
	}
	retained = 0
	for _, rawItem := range items.items {
		item := rawItem.(*pyObject)
		if images, ok := item.Get("images").(*pyList); ok {
			for _, rawImage := range images.items {
				image := rawImage.(*pyObject)
				proof := image.Copy()
				proof.Set("process_id", pid)
				proof.Set("process_start", start)
				proof.Set("session_id", session)
				proof.Set("source_identity", source)
				image.Set("reference", base64.StdEncoding.EncodeToString(pyEncode(proof, conversationCompactJSON)))
			}
		}
		retained += len(pyEncode(item, conversationJSON))
	}
	for len(items.items) > 0 && retained > conversationMaxOutput-8192 {
		revision := phGet(items.items[0], "revision", nil)
		for len(items.items) > 0 && pyEqual(phGet(items.items[0], "revision", nil), revision) {
			retained -= len(pyEncode(items.items[0], conversationJSON))
			items.items = items.items[1:]
		}
		omitted = true
	}
	oldest := scanStart
	if len(items.items) > 0 {
		oldest = phGet(items.items[0], "revision", nil).(int64) - 1
	}
	var cursor any
	if oldest > 0 && (omitted || scanStart > 0) {
		cursor = oldest
	}
	if before != nil {
		control = nil
	}
	return pyObj("version", int64(1), "history", pyObj("before", cursor, "historical", before != nil), "control", control,
		"binding", pyObj("pane_id", pane, "provider", kind, "process_id", pid, "process_start", start, "session_id", session, "source_identity", source),
		"directory", filepath.Dir(path), "items", items, "source_revision", info.Size())
}

func (r *phReader) conversationAttachment(pane string, root int64, binary, reference string) *pyObject {
	if len(reference) > 4096 {
		phRaise(phUnbound, "Invalid image reference.")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(reference)
	if err != nil {
		phRaise(phValueError, "Invalid image reference.")
	}
	proof := phLoadsBytes(data)
	if root == 0 {
		root = r.rootForPane(pane)
	}
	rootStart := r.identity(root)
	pid, kind := r.agent(root, binary, pane)
	start := r.identity(pid)
	verified := r.binding(binary, pane, pid, kind)
	path, session := r.conversationPath(pid, kind, verified)
	var nativeStart any
	if !conversationBound(verified) {
		nativeStart = r.nativeProcessStart(binary, pane, pid, kind)
	}
	expectedStart := start
	if conversationBound(verified) {
		expectedStart = "kernel:" + pyStr(phGet(phIndex(verified, "producer"), "process_start", nil))
	} else if nativeStart != nil {
		expectedStart = "kernel:" + pyStr(nativeStart)
	}
	if !pyEqual(phGet(proof, "process_id", nil), pid) || !pyEqual(phGet(proof, "process_start", nil), expectedStart) || !pyEqual(phGet(proof, "session_id", nil), session) {
		phRaise(phUnbound, "Image reference belongs to a different process or session.")
	}
	offset, index := phGet(proof, "offset", nil), phGet(proof, "index", nil)
	offset64, offsetOK := phIntKey(offset)
	index64, indexOK := phIntKey(index)
	if !phStrictInt(offset) || !offsetOK || offset64 < 0 || !phStrictInt(index) || !indexOK || index64 < 0 || index64 >= 256 {
		phRaise(phUnbound, "Invalid image location.")
	}
	file, info := conversationFile(path, r.uid)
	defer file.Close()
	if !pyEqual(phGet(proof, "source_identity", nil), conversationSource(info)) {
		phRaise(phUnbound, "Image source identity changed.")
	}
	line := conversationLineAt(file, offset64, conversationMaxLine+1)
	if len(line) > conversationMaxLine || !bytes.HasSuffix(line, []byte{'\n'}) {
		phRaise(phUnbound, "Image source exceeds its limit.")
	}
	row := phLoadsBytes(line)
	var message any
	if kind == "claude" {
		message = phGet(row, "message", nil)
	} else {
		message = phGet(row, "payload", nil)
	}
	if !pyTruthy(message) {
		message = newPyObject()
	}
	content := phGet(message, "content", nil)
	if kind == "claude" && (!pyEqual(phGet(row, "sessionId", nil), session) || pyTruthy(phGet(row, "isSidechain", nil))) {
		phRaise(phUnbound, "Image session changed.")
	}
	blocks, ok := content.(*pyList)
	if !ok || index64 >= int64(len(blocks.items)) {
		phRaise(phUnbound, "Image source changed.")
	}
	mime, encoded := conversationEmbeddedImage(blocks.items[index64])
	digest := sha256.Sum256([]byte(encoded))
	if encoded == "" || !pyEqual(mime, phGet(proof, "mime", nil)) || !pyEqual(hex.EncodeToString(digest[:]), phGet(proof, "digest", nil)) {
		phRaise(phUnbound, "Image bytes changed.")
	}
	raw, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil {
		phRaise(phValueError, "Invalid image bytes.")
	}
	if len(raw) == 0 || len(raw) > 8<<20 {
		phRaise(phUnbound, "Image exceeds the 8 MiB preview limit.")
	}
	if conversationSource(phMustStat(path, true)) != conversationSource(info) {
		phRaise(phUnbound, "Image source rotated.")
	}
	r.recheckConversationProcess(root, rootStart, pid, start)
	r.recheckConversationTranscript(pid, kind, path, session, verified)
	if conversationBound(verified) && !pyEqual(r.binding(binary, pane, pid, kind), verified) {
		phRaise(phUnbound, "Image binding changed.")
	}
	return pyObj("version", int64(1), "mime", mime, "data", base64.StdEncoding.EncodeToString(raw))
}

// RunAgentConversation has only read operations: binding, bounded transcript
// history, or the exact bytes referenced by an authenticated image card.
func RunAgentConversation(ctx context.Context, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("agent-conversation", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	pane := flags.String("pane", "", "")
	root := flags.Int64("root-pid", 0, "")
	attachment := flags.String("attachment", "", "")
	bindingOnly := flags.Bool("binding-only", false, "")
	cursor := flags.Int64("before", 0, "")
	source := flags.String("source-identity", "", "")
	session := flags.String("session", "", "")
	if err := flags.Parse(args); err != nil {
		return err
	}
	var before *int64
	flags.Visit(func(f *flag.Flag) {
		if f.Name == "before" {
			before = cursor
		}
	})
	if flags.NArg() != 0 || !phSafeID.MatchString(*pane) || *root < 0 {
		return errors.New("invalid pane selector")
	}
	if before != nil && (*before <= 0 || *source == "" || *session == "") {
		return errors.New("invalid history cursor")
	}
	if len(*source) > 80 || len(*session) > 128 || len(*attachment) > 4096 {
		return errors.New("invalid conversation selector")
	}
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	reader := newPHReader(ctx)
	result := nativeReaderFailure("unbound", func() *pyObject {
		if *bindingOnly {
			return reader.conversationBindingOnly(*pane, *root, binary)
		}
		if *attachment != "" {
			return reader.conversationAttachment(*pane, *root, binary, *attachment)
		}
		return reader.conversationSnapshot(*pane, *root, binary, before, *source, *session)
	})
	maximum := conversationMaxOutput
	if *attachment != "" {
		maximum = 12 << 20
	}
	if len(pyEncode(result, conversationCompactJSON)) > maximum {
		result = pyObj("version", int64(1), "unbound", "Conversation exceeds the snapshot limit.")
	}
	return nativeReaderOutput(out, result, maximum)
}
