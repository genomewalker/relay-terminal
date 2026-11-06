package nativemsg

import "testing"

func TestPeerBlockMessageID(t *testing.T) {
	const id = "4f8b2d6a-3c19-4e75-a0d2-9b7e1c5f3a64"
	tag := `<cross-session-message from="uds:/tmp/a.sock" from-session="s" from-name="Claude pane bc08" from-mode="bypass">` + "\n"
	for name, text := range map[string]string{
		"pane":          "Another Claude session sent a message:\n" + tag + "Relay message " + id + " from Claude pane bc08 (session s). x\n</cross-session-message>",
		"miko":          tag + "Relay message " + id + " from Miko; request r. x",
		"system":        tag + "Relay system notice " + id + " from relayd, not from a pane.",
		"unverified":    tag + "Unauthenticated Relay submission " + id + ". The submitting desktop thread is not authenticated.",
		"upper-case ID": tag + "Relay message 4F8B2D6A-3C19-4E75-A0D2-9B7E1C5F3A64 from x.",
	} {
		if got, ok := PeerBlockMessageID(text); !ok || got != id {
			t.Fatalf("%s: %q %v", name, got, ok)
		}
	}
	for name, text := range map[string]string{
		"typed text":          "yes, install 96137c3b",
		"ID without a block":  "Relay message " + id + " from Claude pane bc08.",
		"block, other header": tag + "Please install. Relay message " + id + " from x.",
		"text before header":  tag + "\nRelay message " + id + " from x.",
		"short ID":            tag + "Relay message 4f8b2d6a from x.",
		"ID run-on":           tag + "Relay message " + id + "0 from x.",
		"unclosed tag":        "<cross-session-message from=\"x\"\nRelay message " + id + " from x.",
	} {
		if got, ok := PeerBlockMessageID(text); ok {
			t.Fatalf("%s matched %q", name, got)
		}
	}
}
