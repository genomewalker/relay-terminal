package daemon

import (
	"fmt"
	"testing"
)

func TestStockCodexManagedProxyTemporaryThreadsCannotReplaceResearchConversation(t *testing.T) {
	for _, method := range []string{"thread/start", "thread/fork"} {
		t.Run(method, func(t *testing.T) {
			s := codexProxySelection{trackPrimary: true}
			proxyRPC(t, &s, true, `{"id":"research","method":"thread/start","params":{}}`)
			proxyRPC(t, &s, false, `{"id":"research","result":{"thread":{"id":"research","path":"/owned/research.jsonl"}}}`)
			before := s.epoch
			proxyRPC(t, &s, true, `{"id":"helper","method":"`+method+`","params":{"threadId":"research","ephemeral":true}}`)
			proxyRPC(t, &s, false, `{"id":"helper","result":{"thread":{"id":"temporary-helper","ephemeral":true}}}`)
			proxyRPC(t, &s, true, `{"id":"helper-turn","method":"turn/start","params":{"threadId":"temporary-helper"}}`)
			proxyRPC(t, &s, false, `{"id":"helper-turn","result":{"turn":{"id":"helper-turn-1"}}}`)
			proxyRPC(t, &s, true, `{"id":"helper-steer","method":"turn/steer","params":{"threadId":"temporary-helper"}}`)
			proxyRPC(t, &s, false, `{"id":"helper-steer","result":{"turnId":"helper-turn-1"}}`)
			proxyRPC(t, &s, true, `{"id":"helper-release","method":"thread/unsubscribe","params":{"threadId":"temporary-helper"}}`)
			proxyRPC(t, &s, false, `{"method":"thread/closed","params":{"threadId":"temporary-helper"}}`)
			proxyRPC(t, &s, true, `{"id":"next-turn","method":"turn/start","params":{"threadId":"research"}}`)
			proxyRPC(t, &s, false, `{"id":"next-turn","result":{"turn":{"id":"turn-2"}}}`)
			if s.session != "research" || s.wanted != "research" || s.path != "/owned/research.jsonl" || s.epoch != before {
				t.Fatalf("temporary %s replaced the pane conversation: session=%q wanted=%q invalidation=%q", method, s.session, s.wanted, s.lastInvalidation)
			}
			if len(s.temporaryThreads) != 0 || len(s.temporaryRequests) != 0 {
				t.Fatal("closed helper tracking was not released")
			}
		})
	}
}

func TestStockCodexManagedProxyPersistentClearStillReplacesResearchConversation(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":1,"method":"thread/start","params":{}}`)
	proxyRPC(t, &s, false, `{"id":1,"result":{"thread":{"id":"research"}}}`)
	proxyRPC(t, &s, true, `{"id":2,"method":"thread/start","params":{"ephemeral":false,"sessionStartSource":"clear"}}`)
	if s.session != "" {
		t.Fatal("a genuine conversation change retained the old binding")
	}
	proxyRPC(t, &s, false, `{"id":2,"result":{"thread":{"id":"fresh"}}}`)
	if s.session != "fresh" || s.wanted != "fresh" {
		t.Fatal("persistent clear did not select the new conversation")
	}
}

func TestStockCodexManagedProxyLateTemporaryReplyCannotCrossConnections(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":"helper","method":"thread/start","params":{"ephemeral":true}}`)
	s.invalidate("connection_changed")
	proxyRPC(t, &s, false, `{"id":"helper","result":{"thread":{"id":"temporary-helper","ephemeral":true}}}`)
	if len(s.temporaryThreads) != 0 || s.session != "" {
		t.Fatal("a late helper reply crossed the connection boundary")
	}
}

func TestStockCodexManagedProxyInterleavedHelperCannotStealExplicitClear(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":1,"method":"thread/start","params":{}}`)
	proxyRPC(t, &s, false, `{"id":1,"result":{"thread":{"id":"research"}}}`)
	proxyRPC(t, &s, true, `{"id":2,"method":"thread/start","params":{"ephemeral":true}}`)
	proxyRPC(t, &s, true, `{"id":3,"method":"thread/start","params":{"ephemeral":false}}`)
	proxyRPC(t, &s, false, `{"id":2,"result":{"thread":{"id":"helper","ephemeral":true}}}`)
	proxyRPC(t, &s, false, `{"id":3,"result":{"thread":{"id":"new-research"}}}`)
	proxyRPC(t, &s, true, `{"id":4,"method":"turn/start","params":{"threadId":"helper"}}`)
	proxyRPC(t, &s, false, `{"id":4,"result":{"turn":{"id":"helper-turn"}}}`)
	proxyRPC(t, &s, false, `{"method":"thread/closed","params":{"threadId":"helper"}}`)
	if s.session != "new-research" || s.wanted != "new-research" {
		t.Fatal("interleaved helper stole the explicit conversation change")
	}
}

func TestStockCodexManagedProxyTemporaryTrackingIsBoundedAndFailsClosed(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	for i := 0; i < 65; i++ {
		proxyRPC(t, &s, true, fmt.Sprintf(`{"id":%d,"method":"thread/start","params":{"ephemeral":true}}`, i))
	}
	if len(s.temporaryRequests) > 64 || s.session != "" {
		t.Fatal("temporary request tracking exceeded its bound or established a binding")
	}
	s.invalidate("connection_changed")
	for i := 0; i < 65; i++ {
		proxyRPC(t, &s, true, fmt.Sprintf(`{"id":%d,"method":"thread/start","params":{"ephemeral":true}}`, i))
		proxyRPC(t, &s, false, fmt.Sprintf(`{"id":%d,"result":{"thread":{"id":"helper-%d","ephemeral":true}}}`, i, i))
	}
	if len(s.temporaryThreads) > 64 || s.session != "" {
		t.Fatal("temporary thread tracking exceeded its bound or established a binding")
	}
}

func TestStockCodexManagedProxyDoesNotBindUnexpectedTemporaryResumeResponse(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":1,"method":"thread/resume","params":{"threadId":"helper"}}`)
	proxyRPC(t, &s, false, `{"id":1,"result":{"thread":{"id":"helper","ephemeral":true}}}`)
	if s.session != "" {
		t.Fatal("temporary resume response established a binding")
	}
}

func TestStockCodexManagedProxyTemporaryThreadCannotEstablishInitialBinding(t *testing.T) {
	s := codexProxySelection{trackPrimary: true}
	proxyRPC(t, &s, true, `{"id":"helper","method":"thread/start","params":{"ephemeral":true}}`)
	proxyRPC(t, &s, false, `{"id":"helper","result":{"thread":{"id":"temporary-helper","ephemeral":true}}}`)
	proxyRPC(t, &s, true, `{"id":"helper-turn","method":"turn/start","params":{"threadId":"temporary-helper"}}`)
	proxyRPC(t, &s, false, `{"id":"helper-turn","result":{"turn":{"id":"helper-turn-1"}}}`)
	if s.session != "" || s.wanted != "" {
		t.Fatal("a temporary helper became the pane's first conversation")
	}
	proxyRPC(t, &s, true, `{"id":"real","method":"thread/start","params":{"ephemeral":false}}`)
	proxyRPC(t, &s, false, `{"id":"real","result":{"thread":{"id":"real","path":"/owned/real.jsonl"}}}`)
	if s.session != "real" {
		t.Fatal("the subsequent persistent conversation was not bound")
	}
}
