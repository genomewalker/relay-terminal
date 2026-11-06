package nativemsg

import (
	"regexp"
	"strings"
)

// peerBlockHeader matches the start of every body deliver writes inside a
// cross-session-message block: the opening tag, a newline, then the message
// kind and its ID.
var peerBlockHeader = regexp.MustCompile(`^<cross-session-message [^>\n]*>\n(?:Relay message|Relay system notice|Unauthenticated Relay submission) ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})[ .;]`)

// PeerBlockMessageID returns the lowercased message ID of the first
// cross-session-message block in text, as deliver framed it. It reads only the
// ID; no text is kept. A block without that header yields false.
func PeerBlockMessageID(text string) (string, bool) {
	start := strings.Index(text, "<cross-session-message ")
	if start < 0 {
		return "", false
	}
	match := peerBlockHeader.FindStringSubmatch(text[start:])
	if match == nil {
		return "", false
	}
	return strings.ToLower(match[1]), true
}
