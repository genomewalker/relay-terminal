package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// desktopSessionSource is the actor proof a Claude desktop session presents.
// The daemon re-derives the same proof from the calling process's kernel
// ancestry; this client only chooses which operation to ask for.
const desktopSessionSource = "claude_desktop_session_kernel_owner"

// desktopSessionNote states what the sender can expect back.
const desktopSessionNote = "A reply from the pane is delivered back to this Claude desktop session over the approved link; read this send's receipt with relay_pane_message_receipt."

var canonicalUUIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// desktopSessionSend sends from a verified Claude desktop session to one pane
// by the daemon's remote_send, with no link ID: the daemon resolves the one
// saved link that pairs this session with the pane, and only after an owner
// approved it. The sender is the proven session, never an argument.
func (s *server) desktopSessionSend(actor string, arguments map[string]json.RawMessage, targeted bool) (any, bool) {
	fail := func(text string) (any, bool) {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": true}, true
	}
	if targeted {
		return fail("target_session_id is not available for a Claude desktop session send. Nothing was sent.")
	}
	for key := range arguments {
		switch key {
		case "source_pane_id", "pane_id", "message_id", "text":
		default:
			return fail("Unexpected argument for a Claude desktop session send: " + key + ". Nothing was sent.")
		}
	}
	var source, pane, message, text string
	for key, target := range map[string]*string{"source_pane_id": &source, "pane_id": &pane, "message_id": &message, "text": &text} {
		raw, present := arguments[key]
		if !present {
			continue
		}
		if json.Unmarshal(raw, target) != nil {
			return fail("Communication arguments must be strings. Nothing was sent.")
		}
	}
	if source != "" && !strings.EqualFold(source, actor) {
		return fail("Sender must be this Claude desktop session. Nothing was sent.")
	}
	pane = strings.ToLower(pane)
	if !canonicalUUIDPattern.MatchString(pane) {
		return fail("pane_id must be a pane UUID. Nothing was sent.")
	}
	if s.callerToken == "" {
		return fail("A Claude desktop session send needs a registered caller credential. Nothing was sent.")
	}
	if message == "" {
		var id [16]byte
		if _, err := rand.Read(id[:]); err != nil {
			return fail("Message identity unavailable. Nothing was sent.")
		}
		message = fmt.Sprintf("%x-%x-4%x-8%x-%x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16])
	}
	packet := map[string]any{"operation": "remote_send", "source_pane_id": strings.ToLower(actor), "actor_pane_id": strings.ToLower(actor),
		"pane_id": pane, "message_id": strings.ToLower(message), "text": text, "client_token": s.callerToken, "link_id": ""}
	encoded, err := json.Marshal(packet)
	if err != nil || len(encoded) > 65536 {
		return fail("Communication request exceeds limit. Nothing was sent.")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		return fail(fmt.Sprintf("Daemon communication unavailable: %s. Nothing was sent.", strings.TrimSpace(stderr.String())))
	}
	if out.Len() > 128<<10 || !json.Valid(out.Bytes()) {
		return fail("Invalid daemon communication response")
	}
	return map[string]any{"content": []map[string]any{{"type": "text", "text": out.String() + "\n" + desktopSessionNote}}, "isError": false}, true
}

// desktopSessionLink asks the owner to approve a route link from this verified
// desktop session to one exact pane. It creates nothing: the daemon records a
// pending request, and the link exists only after the owner approves it in Relay.
func (s *server) desktopSessionLink(actor string, arguments map[string]json.RawMessage, targeted bool) (any, bool) {
	fail := func(text string) (any, bool) {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": true}, true
	}
	if targeted {
		return fail("target_session_id does not apply to a link request. Nothing was requested.")
	}
	var source, pane string
	for key := range arguments {
		switch key {
		case "source_pane_id", "pane_id":
		default:
			return fail("Unexpected argument for a Claude desktop session link: " + key + ". Nothing was requested.")
		}
	}
	for key, target := range map[string]*string{"source_pane_id": &source, "pane_id": &pane} {
		raw, present := arguments[key]
		if present && json.Unmarshal(raw, target) != nil {
			return fail("Communication arguments must be strings. Nothing was requested.")
		}
	}
	if source != "" && !strings.EqualFold(source, actor) {
		return fail("Sender must be this Claude desktop session. Nothing was requested.")
	}
	pane = strings.ToLower(pane)
	if !canonicalUUIDPattern.MatchString(pane) || strings.EqualFold(pane, actor) {
		return fail("pane_id must be one other pane UUID. Nothing was requested.")
	}
	if s.callerToken == "" {
		return fail("A Claude desktop session link request needs a registered caller credential. Nothing was requested.")
	}
	packet := map[string]any{"operation": "desktop_link_request", "source_pane_id": strings.ToLower(actor),
		"actor_pane_id": strings.ToLower(actor), "pane_id": pane, "client_token": s.callerToken}
	encoded, err := json.Marshal(packet)
	if err != nil {
		return fail("Request encoding failed. Nothing was requested.")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		return fail(fmt.Sprintf("Daemon communication unavailable: %s. Nothing was requested.", strings.TrimSpace(stderr.String())))
	}
	if out.Len() > 128<<10 || !json.Valid(out.Bytes()) {
		return fail("Invalid daemon communication response")
	}
	text := out.String() + "\nThe owner must approve this link in Relay on the Mac before any message can be sent. " + desktopSessionNote
	return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": false}, true
}

// desktopSessionInbox returns the replies delivered to this verified desktop
// session under its current registration. It takes no arguments.
func (s *server) desktopSessionInbox(actor string, arguments map[string]json.RawMessage) (any, bool) {
	fail := func(text string) (any, bool) {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": true}, true
	}
	if len(arguments) != 0 {
		return fail("relay_read_desktop_inbox takes no arguments.")
	}
	packet := map[string]any{"operation": "desktop_inbox_read", "source_pane_id": strings.ToLower(actor), "actor_pane_id": strings.ToLower(actor)}
	encoded, err := json.Marshal(packet)
	if err != nil {
		return fail("Request encoding failed.")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		return fail(fmt.Sprintf("Daemon communication unavailable: %s.", strings.TrimSpace(stderr.String())))
	}
	if out.Len() > 128<<10 || !json.Valid(out.Bytes()) {
		return fail("Invalid daemon communication response")
	}
	return map[string]any{"content": []map[string]any{{"type": "text", "text": out.String()}}, "isError": false}, true
}
