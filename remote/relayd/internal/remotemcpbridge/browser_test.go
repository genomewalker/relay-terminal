package remotemcpbridge

import (
	"fmt"
	"testing"
)

func TestBrowserIsLimitedToThisHostsPanes(t *testing.T) {
	body := func(pane string) string {
		return fmt.Sprintf(`{"instance":%q,"requestID":%q,"paneID":%q,"action":"read"}`, wsInstance, wsReq, pane)
	}
	var got []fwd
	b := wsBridge(&got)
	if s, out := post(b, "/api/workspace/browser", body(sourcePane)); s != 200 {
		t.Fatalf("own pane refused: %d %s", s, out)
	}
	if len(got) != 1 || got[0].path != "/api/workspace/browser" {
		t.Fatalf("not forwarded: %#v", got)
	}
	for _, pane := range []string{foreignPane, "bbbbbbbb-0000-0000-0000-000000000002", "not-a-pane"} {
		if s, _ := post(b, "/api/workspace/browser", body(pane)); s != 403 {
			t.Fatalf("pane %s outside scope got %d", pane, s)
		}
	}
	if len(got) != 1 {
		t.Fatal("a refused browser request was forwarded")
	}
}
