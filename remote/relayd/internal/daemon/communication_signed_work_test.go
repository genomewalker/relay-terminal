package daemon

import (
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func TestCommunicationSignedWorkTargetDomainAndIdentity(t *testing.T) {
	h := newSigningHost(t, signerNode)
	r := signRequest("payload")
	target := nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner-1", Incarnation: "123:456"}
	encoded, err := communicationSignWork(h.root, h.node, r, receiverNode, strings.Repeat("a", 64), 3, 4, target, h.deps())
	if err != nil {
		t.Fatal(err)
	}
	trust := []communicationTrustedNode{h.trusted()}
	verified, err := communicationVerifyWorkEnvelope(encoded, trust, h.clock)
	if err != nil || verified.Statement.WorkTarget == nil || *verified.Statement.WorkTarget != target || verified.Statement.TargetPaneID != "" || verified.Statement.TextSHA256 != communicationTextDigest(r.Text) {
		t.Fatal(verified, err)
	}
	if _, err := communicationVerifyEnvelope(encoded, trust, h.clock); err == nil {
		t.Fatal("Work signature accepted as a pane message")
	}
	pane := h.sign(t, r)
	if _, err := communicationVerifyWorkEnvelope(pane, trust, h.clock); err == nil {
		t.Fatal("pane signature accepted as a Work message")
	}
	if _, err := communicationVerifyWorkEnvelope(encoded, trust, h.clock.Add(communicationStatementTTL)); err == nil {
		t.Fatal("expired proof accepted")
	}
	r.actorVerified = false
	if _, err := communicationSignWork(h.root, h.node, r, receiverNode, strings.Repeat("a", 64), 3, 4, target, h.deps()); err == nil {
		t.Fatal("unverified actor signed")
	}
	r.actorVerified = true
	target.Owner = "owner\ninjection"
	if _, err := communicationSignWork(h.root, h.node, r, receiverNode, strings.Repeat("a", 64), 3, 4, target, h.deps()); err == nil {
		t.Fatal("invalid owner signed")
	}
}

func TestCommunicationSignedWorkRejectsDifferentTarget(t *testing.T) {
	h := newSigningHost(t, signerNode)
	r := signRequest("payload")
	target := nativemsg.WorkEndpoint{Thread: "task-1", Owner: "owner-1", Incarnation: "123:456"}
	encoded, err := communicationSignWork(h.root, h.node, r, receiverNode, strings.Repeat("a", 64), 3, 4, target, h.deps())
	if err != nil {
		t.Fatal(err)
	}
	trust := []communicationTrustedNode{h.trusted()}
	session := h.member.SessionID
	check := func(node, pane, session, id, text string, expected nativemsg.WorkEndpoint) error {
		_, err := communicationVerifyWorkMessage(encoded, trust, h.clock, node, pane, h.member.Provider, session, receiverNode, id, strings.Repeat("a", 64), 3, 4, []byte(text), expected)
		return err
	}
	if err := check(h.node, r.SourcePaneID, session, r.MessageID, r.Text, target); err != nil {
		t.Fatal(err)
	}
	for _, candidate := range []nativemsg.WorkEndpoint{{Thread: "task-2", Owner: target.Owner, Incarnation: target.Incarnation}, {Thread: target.Thread, Owner: "other", Incarnation: target.Incarnation}, {Thread: target.Thread, Owner: target.Owner, Incarnation: "999:000"}} {
		if err := check(h.node, r.SourcePaneID, session, r.MessageID, r.Text, candidate); err == nil {
			t.Fatal("target substitution accepted")
		}
	}
	if err := check(h.node, r.SourcePaneID, session, r.MessageID, "different", target); err == nil {
		t.Fatal("changed content accepted")
	}
	if err := check(h.node, r.SourcePaneID, session, targetFixturePane, r.Text, target); err == nil {
		t.Fatal("changed message ID accepted")
	}
	if err := check(h.node, targetFixturePane, session, r.MessageID, r.Text, target); err == nil {
		t.Fatal("changed source pane accepted")
	}
	if _, err := communicationVerifyWorkMessage(encoded, trust, h.clock, h.node, r.SourcePaneID, h.member.Provider, session, "different-node", r.MessageID, strings.Repeat("a", 64), 3, 4, []byte(r.Text), target); err == nil {
		t.Fatal("changed target node accepted")
	}
	if _, err := communicationVerifyWorkMessage(encoded, trust, h.clock, h.node, r.SourcePaneID, "claude", session, receiverNode, r.MessageID, strings.Repeat("a", 64), 3, 4, []byte(r.Text), target); err == nil {
		t.Fatal("changed source provider accepted")
	}
	if _, err := communicationVerifyWorkMessage(encoded, trust, h.clock, h.node, r.SourcePaneID, h.member.Provider, session, receiverNode, r.MessageID, strings.Repeat("b", 64), 3, 4, []byte(r.Text), target); err == nil {
		t.Fatal("different link accepted")
	}
	if _, err := communicationVerifyWorkMessage(encoded, trust, h.clock, h.node, r.SourcePaneID, h.member.Provider, session, receiverNode, r.MessageID, strings.Repeat("a", 64), 3, 5, []byte(r.Text), target); err == nil {
		t.Fatal("different link revision accepted")
	}

}
