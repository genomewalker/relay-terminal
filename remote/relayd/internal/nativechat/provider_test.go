package nativechat

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func driverFor(t testing.TB, provider string) *Driver {
	t.Helper()
	s, e := NewState(Identity{"pane", "instance", provider}, "/workspace", "model")
	if e != nil {
		t.Fatal(e)
	}
	o := ProviderOptions{Provider: provider, CWD: "/workspace", Model: "model", Session: "session"}
	d, e := NewDriver(s, o)
	if e != nil {
		t.Fatal(e)
	}
	return d
}
func consume(t testing.TB, d *Driver, raw string) []json.RawMessage {
	t.Helper()
	frames, e := d.Consume([]byte(raw))
	if e != nil {
		t.Fatal(e)
	}
	return frames
}
func claimCommand(t testing.TB, d *Driver, a Action) json.RawMessage {
	t.Helper()
	a.Identity = d.State.View.Identity
	if _, fresh, e := d.State.Claim(a); e != nil || !fresh {
		t.Fatalf("claim %v %v", fresh, e)
	}
	b, e := d.Command(a)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func TestCodexNativeFixture(t *testing.T) {
	d := driverFor(t, "codex")
	frames := consume(t, d, `{"id":"relay-initialize","result":{}}`)
	if len(frames) != 2 || str(obj(frames[1])["method"]) != "thread/start" {
		t.Fatal("native thread not initialized")
	}
	consume(t, d, `{"id":"relay-thread","result":{"thread":{"id":"session","turns":[]}}}`)
	sent := claimCommand(t, d, Action{ID: "send", Kind: "send", Text: "hello"})
	if str(obj(sent)["method"]) != "turn/start" || str(obj(obj(sent)["params"])["threadId"]) != "session" {
		t.Fatal("wrong thread input")
	}
	consume(t, d, `{"id":"relay-send","result":{"turn":{"id":"turn"}}}`)
	consume(t, d, `{"method":"item/agentMessage/delta","params":{"threadId":"session","turnId":"turn","itemId":"message","delta":"Hi"}}`)
	consume(t, d, `{"method":"item/completed","params":{"threadId":"session","turnId":"turn","item":{"type":"agentMessage","id":"message","text":"Hi there"}}}`)
	if len(d.State.View.Items) != 1 || d.State.View.Items[0].Text != "Hi there" {
		t.Fatal("completed message duplicated or lost")
	}
	consume(t, d, `{"id":17,"method":"item/commandExecution/requestApproval","params":{"threadId":"session","turnId":"turn","command":"echo ok","availableDecisions":["accept","decline"]}}`)
	r := d.State.View.Requests[0]
	reply := claimCommand(t, d, Action{ID: "answer", Kind: "respond", RequestID: r.ID, TurnID: r.TurnID, Decision: "allow"})
	if string(obj(reply)["id"]) != "17" || str(obj(obj(reply)["result"])["decision"]) != "accept" {
		t.Fatal("native approval ID or decision changed")
	}
	consume(t, d, `{"method":"serverRequest/resolved","params":{"threadId":"session","requestId":17}}`)
	stop := claimCommand(t, d, Action{ID: "stop", Kind: "interrupt", TurnID: "turn"})
	if str(obj(obj(stop)["params"])["turnId"]) != "turn" {
		t.Fatal("interrupt lost exact turn")
	}
	consume(t, d, `{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"turn","status":"interrupted"}}}`)
	if !d.State.Snapshot().Capabilities.Send || len(d.State.View.Requests) != 0 {
		t.Fatal("next turn unavailable")
	}
}
func TestClaudeNativeFixture(t *testing.T) {
	d := driverFor(t, "claude")
	consume(t, d, `{"type":"control_response","response":{"request_id":"relay-initialize","subtype":"success","response":{}}}`)
	sent := claimCommand(t, d, Action{ID: "send", Kind: "send", Text: "hello"})
	if str(obj(sent)["session_id"]) != "session" || str(obj(sent)["type"]) != "user" {
		t.Fatal("wrong Claude session")
	}
	consume(t, d, `{"type":"stream_event","session_id":"session","event":{"type":"message_start","message":{"id":"message"}}}`)
	consume(t, d, `{"type":"stream_event","session_id":"session","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`)
	consume(t, d, `{"type":"stream_event","session_id":"session","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}`)
	consume(t, d, `{"type":"assistant","session_id":"session","message":{"id":"message","content":[{"type":"text","text":"Hi there"}]}}`)
	if len(d.State.View.Items) != 1 || d.State.View.Items[0].Text != "Hi there" {
		t.Fatal("Claude final text duplicated or lost")
	}
	consume(t, d, `{"type":"control_request","request_id":"native-question","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Choose","header":"Pick","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}],"extra":"preserve"}}}`)
	r := d.State.View.Requests[0]
	// A result does not erase a background control request.
	consume(t, d, `{"type":"result","session_id":"session","is_error":false}`)
	if len(d.State.View.Requests) != 1 {
		t.Fatal("background question erased")
	}
	reply := claimCommand(t, d, Action{ID: "answer", Kind: "respond", RequestID: r.ID, TurnID: r.TurnID, Answers: map[string][]string{"question-0": {"A", "B"}}})
	response := obj(obj(reply)["response"])
	answer := obj(response["response"])
	input := obj(answer["updatedInput"])
	if str(response["request_id"]) != "native-question" || str(answer["behavior"]) != "allow" || str(obj(input["answers"])["Choose"]) != "A, B" || str(input["extra"]) != "preserve" {
		t.Fatal("question answer semantics changed")
	}
	d.State.ResolveRequest(r.ID)
	if !d.State.Snapshot().Capabilities.Send || d.State.Snapshot().Capabilities.InterruptScope != "session" {
		t.Fatal("Claude capability scope incorrect")
	}
}
func TestProviderRejectsWrongConversation(t *testing.T) {
	d := driverFor(t, "claude")
	_ = d.State.Ready("session")
	before, _ := json.Marshal(d.State)
	if _, e := d.Consume([]byte(`{"type":"system","subtype":"init","session_id":"other"}`)); e == nil {
		t.Fatal("wrong Claude session accepted")
	}
	after, _ := json.Marshal(d.State)
	if !bytes.Equal(before, after) {
		t.Fatal("wrong session changed state")
	}
	c := driverFor(t, "codex")
	_ = c.State.Ready("session")
	_ = c.State.Running("turn")
	before, _ = json.Marshal(c.State)
	consume(t, c, `{"method":"turn/completed","params":{"threadId":"other","turn":{"id":"turn","status":"completed"}}}`)
	after, _ = json.Marshal(c.State)
	if !bytes.Equal(before, after) {
		t.Fatal("foreign thread changed active state")
	}
}
func TestIdentityCannotEscapeRoot(t *testing.T) {
	for _, segment := range []string{".", "..", "../x", "x/y", `x\y`, "", strings.Repeat("x", 129)} {
		if (Identity{segment, "instance", "codex"}).Valid() || (Identity{"pane", segment, "claude"}).Valid() {
			t.Fatalf("unsafe path segment %q accepted", segment)
		}
	}
}
func FuzzIdentityRoot(f *testing.F) {
	for _, seed := range []string{"pane", "..", ".", "x/y", "x:y", "good-uuid"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, segment string) {
		id := Identity{segment, segment, "codex"}
		if !id.Valid() {
			return
		}
		root := filepath.Join(string(filepath.Separator), "relay", "native-chat")
		path := filepath.Join(root, id.Pane, id.Instance)
		rel, e := filepath.Rel(root, path)
		if e != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			t.Fatal("identity escaped root")
		}
	})
}
func TestRPCEnvelopeRejectsMixedOperations(t *testing.T) {
	for _, raw := range []string{
		`{"operation":"snapshot","identity":{"pane":"p","instance":"i","provider":"codex"},"imageData":"eA=="}`,
		`{"operation":"action","identity":{"pane":"p","instance":"i","provider":"codex"},"action":{"id":"x","kind":"send","identity":{"pane":"other","instance":"i","provider":"codex"},"text":"hi"}}`,
		`{"operation":"receipt","identity":{"pane":"p","instance":"i","provider":"codex"},"receiptId":"x","before":2}`,
	} {
		if _, e := DecodeRPC([]byte(raw)); e == nil {
			t.Fatal("mixed or foreign RPC envelope accepted")
		}
	}
}
func FuzzRPCEnvelope(f *testing.F) {
	f.Add([]byte(`{"operation":"snapshot","identity":{"pane":"p","instance":"i","provider":"codex"},"imageData":""}`))
	for _, raw := range []string{
		`{"operation":"snapshot","identity":{"pane":"p","instance":"i","provider":"codex"}}`,
		`{"operation":"receipt","identity":{"pane":"p","instance":"i","provider":"codex"},"receiptId":"a"}`,
		`{"operation":"image","identity":{"pane":"p","instance":"i","provider":"claude"},"imageData":"eA=="}`,
	} {
		f.Add([]byte(raw))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > MaxActionBytes {
			return
		}
		r, e := DecodeRPC(data)
		if e != nil {
			return
		}
		again, e := DecodeRPC(wire(r))
		if e != nil || !reflect.DeepEqual(r, again) {
			t.Fatal("RPC round trip changed action")
		}
		if _, e := DecodeRPC(append(bytes.Clone(data), '}')); e == nil {
			t.Fatal("trailing protocol accepted")
		}
	})
}
func FuzzProviderFrames(f *testing.F) {
	for _, s := range []string{`{"type":"result","session_id":"session"}`, `{"method":"turn/completed","params":{"threadId":"other","turn":{"id":"turn","status":"completed"}}}`, `{"type":"system","subtype":"init","session_id":"other"}`, `{"id":`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > MaxActionBytes {
			return
		}
		for _, provider := range []string{"codex", "claude"} {
			d := driverFor(t, provider)
			_ = d.State.Ready("session")
			_ = d.State.Running("turn")
			identity := d.State.View.Identity
			frames, _ := d.Consume(data)
			if d.State.View.Identity != identity || d.State.View.SessionID != "session" {
				t.Fatal("frame rebound conversation")
			}
			if len(d.State.View.Items) > MaxItems || len(d.State.View.Requests) > 16 {
				t.Fatal("frame exceeded state bounds")
			}
			for _, i := range d.State.View.Items {
				if len(i.Text) > MaxItemBytes {
					t.Fatal("unbounded provider item")
				}
			}
			for _, frame := range frames {
				if _, e := DecodeObject(frame, MaxFrameBytes); e != nil {
					t.Fatal("driver produced malformed response", e)
				}
			}
		}
	})
}

func TestClaudeBusyStateDefersNextSend(t *testing.T) {
	d := driverFor(t, "claude")
	_ = d.State.Ready("session")
	_ = claimCommand(t, d, Action{ID: "send", Kind: "send", Text: "hello"})
	consume(t, d, `{"type":"system","subtype":"session_state_changed","state":"running","session_id":"session"}`)
	consume(t, d, `{"type":"result","session_id":"session","is_error":false}`)
	if d.State.Snapshot().Capabilities.Send {
		t.Fatal("result reopened composer while provider reports busy")
	}
	consume(t, d, `{"type":"system","subtype":"session_state_changed","state":"idle","session_id":"session"}`)
	if !d.State.Snapshot().Capabilities.Send {
		t.Fatal("idle notification did not reopen composer")
	}
}
