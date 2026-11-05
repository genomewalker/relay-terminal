package main

import (
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/workorigin"
	"strings"
	"testing"
)

func workArgs(t *testing.T, s string) map[string]json.RawMessage {
	t.Helper()
	var a map[string]json.RawMessage
	if err := json.Unmarshal([]byte(s), &a); err != nil {
		t.Fatal(err)
	}
	return a
}
func TestWorkArgumentsExcludeSourceAndKeepStableIDs(t *testing.T) {
	link := strings.Repeat("a", 64)
	id := "7d85fd72-64ec-46a4-8591-567bf64f7c93"
	valid := `{"link_id":"` + link + `","message_id":"` + id + `","text":"hello"}`
	p, err := workPacket("relay_work_message", workArgs(t, valid))
	if err != nil || p["message_id"] != id || p["operation"] != "send" {
		t.Fatalf("%+v %v", p, err)
	}
	for _, extra := range []string{`,"protected_thread_id":"forged"`, `,"source_pane_id":"` + id + `"`, `,"helper_pid":42`, `,"_meta":{"threadId":"forged"}`} {
		if _, err := workPacket("relay_work_message", workArgs(t, valid[:len(valid)-1]+extra+"}")); err == nil {
			t.Fatal("accepted forged source")
		}
	}
	for _, rev := range []string{"0", "-1", "1.5", "18446744073709551616"} {
		if _, err := workPacket("relay_repair_work_link", workArgs(t, `{"link_id":"`+link+`","request_id":"`+id+`","expected_revision":`+rev+`}`)); err == nil {
			t.Fatal("invalid revision accepted")
		}
	}
}
func TestWorkCatalogAndOneShotDoNotRequireLiveState(t *testing.T) {
	var out strings.Builder
	if err := runWorkRequest(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`), &out); err != nil {
		t.Fatal(err)
	}
	var response struct {
		Result struct {
			Tools []json.RawMessage `json:"tools"`
		} `json:"result"`
	}
	if json.Unmarshal([]byte(out.String()), &response) != nil || len(response.Result.Tools) != 5 {
		t.Fatal(out.String())
	}
}

func TestWorkThreadComesOnlyFromVerifiedProviderMetadata(t *testing.T) {
	oldAuth, oldValidate, oldDelegate := workAuthenticate, workRevalidate, workDelegate
	t.Cleanup(func() { workAuthenticate = oldAuth; workRevalidate = oldValidate; workDelegate = oldDelegate })
	thread := "01a18b32-f284-7220-91a2-6a81cde6db14"
	link := strings.Repeat("a", 64)
	var packet map[string]any
	calls := 0
	workAuthenticate = func(pid int, got string) (workorigin.Source, error) {
		if pid <= 1 || got != thread {
			return workorigin.Source{}, errors.New("unverified")
		}
		return workorigin.Source{Thread: thread}, nil
	}
	workRevalidate = func(workorigin.Evidence) error { return nil }
	workDelegate = func(p map[string]any) ([]byte, error) { packet = p; calls++; return []byte(`{"state":"held"}`), nil }
	call := func(params string) {
		t.Helper()
		_, code, _ := handleWorkRequest(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/call", Params: json.RawMessage(params)})
		if code != 0 {
			t.Fatalf("code=%d", code)
		}
	}
	call(`{"name":"relay_work_link_status","arguments":{"link_id":"` + link + `"},"_meta":{"threadId":"` + thread + `"}}`)
	if packet["protected_thread_id"] != thread {
		t.Fatal("verified metadata was not bound to request")
	}
	workAuthenticate = func(int, string) (workorigin.Source, error) {
		return workorigin.Source{}, errors.New("not a native Work transport")
	}
	call(`{"name":"relay_work_link_status","arguments":{"link_id":"` + link + `"},"_meta":{"threadId":"` + thread + `"}}`)
	if _, ok := packet["protected_thread_id"]; ok {
		t.Fatal("unverified metadata promoted to Work origin")
	}
	before := calls
	_, code, _ := handleWorkRequest(request{JSONRPC: "2.0", ID: json.RawMessage("2"), Method: "tools/call", Params: json.RawMessage(`{"name":"relay_work_link_status","arguments":{"link_id":"` + link + `","protected_thread_id":"` + thread + `"}}`)})
	if code == 0 || calls != before {
		t.Fatal("source argument reached daemon")
	}
	workAuthenticate = func(int, string) (workorigin.Source, error) { return workorigin.Source{Thread: thread}, nil }
	workRevalidate = func(workorigin.Evidence) error { return errors.New("pipe changed") }
	before = calls
	call(`{"name":"relay_work_link_status","arguments":{"link_id":"` + link + `"},"_meta":{"threadId":"` + thread + `"}}`)
	if calls != before {
		t.Fatal("changed transport reached daemon")
	}
}

func TestWorkSendFileArguments(t *testing.T) {
	link := strings.Repeat("a", 64)
	id := "01a18b32-f284-7220-91a2-6a81cde6db14"
	sum := strings.Repeat("b", 64)
	base := `"link_id":"` + link + `","message_id":"` + id + `","path":"/tmp/draft.txt","sha256":"` + sum + `"`
	p, err := workPacket("relay_work_send_file", workArgs(t, `{`+base+`}`))
	if err != nil || p["operation"] != "send_file" || p["file_sha256"] != sum || p["path"] != "/tmp/draft.txt" || p["sha256"] != nil {
		t.Fatal(p, err)
	}
	if p, err = workPacket("relay_work_send_file", workArgs(t, `{`+base+`,"text":"note"}`)); err != nil || p["text"] != "note" {
		t.Fatal(p, err)
	}
	for _, bad := range []string{
		`{"link_id":"` + link + `","message_id":"` + id + `","path":"/tmp/x","text":"no digest"}`,
		`{"link_id":"` + link + `","message_id":"` + id + `","path":"relative","sha256":"` + sum + `"}`,
		`{"link_id":"` + link + `","message_id":"` + id + `","path":"/tmp/x","sha256":"ABC"}`,
		`{` + base + `,"source":"x"}`,
	} {
		if _, err := workPacket("relay_work_send_file", workArgs(t, bad)); err == nil {
			t.Fatal("accepted", bad)
		}
	}
	if _, err := workPacket("relay_work_message", workArgs(t, `{"link_id":"`+link+`","message_id":"`+id+`","text":"x","path":"/tmp/x"}`)); err == nil {
		t.Fatal("path on plain message accepted")
	}
}
