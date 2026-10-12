package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testGroupID = "11111111-1111-4111-8111-111111111111"
const testGroupA = "22222222-2222-4222-8222-222222222222"
const testGroupB = "33333333-3333-4333-8333-333333333333"

func groupFixture(t *testing.T) (string, CommunicationRequest, map[string]string) {
	t.Helper()
	return t.TempDir(), CommunicationRequest{Operation: "group_set", GroupID: testGroupID, GroupName: "Review",
		ClientID: "fixture-caller", MemberPaneIDs: []string{testGroupB, testGroupA}}, map[string]string{testGroupA: "A", testGroupB: "B"}
}
func TestCommunicationGroupPersistsCASAndRetiredHistory(t *testing.T) {
	root, r, known := groupFixture(t)
	result, err := communicationGroupOperation(root, "node", r, known)
	if err != nil {
		t.Fatal(err)
	}
	group := result["group"].(communicationGroup)
	if group.Revision != 1 || group.Members[0] != testGroupA {
		t.Fatal(group)
	}
	stale := r
	stale.GroupName = "stale"
	if _, err := communicationGroupOperation(root, "node", stale, known); err == nil {
		t.Fatal("stale revision accepted")
	}
	r.ExpectedGroupRevision = 1
	r.GroupName = "Updated"
	if _, err := communicationGroupOperation(root, "node", r, known); err != nil {
		t.Fatal(err)
	}
	result, err = communicationGroupOperation(root, "node", CommunicationRequest{Operation: "group_get", GroupID: testGroupID}, nil)
	if err != nil || result["group"].(communicationGroup).Revision != 2 {
		t.Fatal(result, err)
	}
	retire := CommunicationRequest{Operation: "group_retire", GroupID: testGroupID, ClientID: r.ClientID, ExpectedGroupRevision: 2}
	result, err = communicationGroupOperation(root, "node", retire, nil)
	if err != nil || !result["group"].(communicationGroup).Retired || result["group"].(communicationGroup).Revision != 3 {
		t.Fatal(result, err)
	}
	r.ExpectedGroupRevision = 3
	result, err = communicationGroupOperation(root, "node", r, known)
	if err != nil || result["group"].(communicationGroup).Retired {
		t.Fatal("owned restoration failed", err)
	}
	info, err := os.Stat(filepath.Join(root, "group-"+testGroupID+".json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("private group mode", err)
	}
	if info, err := os.Stat(filepath.Join(root, "events.jsonl")); err != nil || info.Size() == 0 {
		t.Fatal("durable events", err)
	}
}
func TestCommunicationGroupRejectsOwnerNodeAndMemberChanges(t *testing.T) {
	root, r, known := groupFixture(t)
	if _, err := communicationGroupOperation(root, "node", r, known); err != nil {
		t.Fatal(err)
	}
	other := r
	other.ClientID = "other-caller"
	other.ExpectedGroupRevision = 1
	if _, err := communicationGroupOperation(root, "node", other, known); err == nil {
		t.Fatal("foreign caller changed group")
	}
	if _, err := communicationGroupOperation(root, "other-node", CommunicationRequest{Operation: "group_get", GroupID: testGroupID}, nil); err == nil {
		t.Fatal("foreign node accepted group")
	}
	for _, members := range [][]string{{testGroupA, testGroupA}, {testGroupA, testGroupID}, {testGroupA}, {testGroupA, strings.Repeat("x", 36)}} {
		bad := r
		bad.ExpectedGroupRevision = 1
		bad.MemberPaneIDs = members
		if _, err := communicationGroupOperation(root, "node", bad, known); err == nil {
			t.Fatal("invalid members accepted", members)
		}
	}
	bad := r
	bad.ExpectedGroupRevision = 1
	bad.ActorPaneID = testGroupID
	if _, err := communicationGroupOperation(root, "node", bad, known); err == nil {
		t.Fatal("nonmember actor accepted")
	}
}
func TestCommunicationGroupNamesAndLimit(t *testing.T) {
	for _, name := range []string{"", "\n", "unsafe\nname", "bad\x1bname", string([]byte{255}), strings.Repeat("x", 121)} {
		if validCommunicationGroupName(name) {
			t.Fatalf("invalid name %q", name)
		}
	}
	root, r, known := groupFixture(t)
	for n := 0; n < communicationMaxGroups; n++ {
		p := filepath.Join(root, "group-"+fmt.Sprintf("%08d", n)+".json")
		if err := os.WriteFile(p, []byte("{}"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := communicationGroupOperation(root, "node", r, known); err == nil {
		t.Fatal("group limit bypass")
	}
}
func TestCommunicationGroupMutationsRespectCallerPauseAndActor(t *testing.T) {
	root := t.TempDir()
	token := "fixture-credential"
	hash := sha256.Sum256([]byte(token))
	policy := communicationPolicy{Callers: []communicationCaller{{ID: testGroupID, Label: "fixture",
		TokenHash: hex.EncodeToString(hash[:]), Paused: true}}}
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	for _, op := range []string{"group_set", "group_retire"} {
		_, err := communicationAuthorize(root, CommunicationRequest{Operation: op, ClientToken: token,
			ActorPaneID: testGroupA, SourcePaneID: testGroupA})
		if err == nil {
			t.Fatal("paused group mutation accepted", op)
		}
	}
	if _, err := communicationAuthorize(root, CommunicationRequest{Operation: "group_set", ActorPaneID: testGroupA, SourcePaneID: testGroupB}); err == nil {
		t.Fatal("foreign actor group mutation accepted")
	}
}

func TestCommunicationGroupDispatcherReadsWithoutDesktop(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	node, _ := currentNodeIdentity()
	r := CommunicationRequest{Operation: "group_set", GroupID: testGroupID, GroupName: "Offline membership",
		ClientID: "owner", MemberPaneIDs: []string{testGroupA, testGroupB}}
	known := map[string]string{testGroupA: "A", testGroupB: "B"}
	if _, err := communicationGroupOperation(root, node, r, known); err != nil {
		t.Fatal(err)
	}
	got, err := ExecuteCommunication(CommunicationRequest{Operation: "group_get", GroupID: testGroupID})
	if err != nil || got["group"].(communicationGroup).Revision != 1 || got["desktop_required"] != false {
		t.Fatal("daemon-local read required a desktop", got, err)
	}
	list, err := ExecuteCommunication(CommunicationRequest{Operation: "group_list"})
	if err != nil || len(list["groups"].([]communicationGroup)) != 1 {
		t.Fatal(list, err)
	}
}
func TestCommunicationGroupSupportsMoreThanPairAndMemberBound(t *testing.T) {
	root, r, known := groupFixture(t)
	r.MemberPaneIDs = append(r.MemberPaneIDs, testGroupID)
	known[testGroupID] = "C"
	result, err := communicationGroupOperation(root, "node", r, known)
	if err != nil || len(result["group"].(communicationGroup).Members) != 3 {
		t.Fatal(result, err)
	}
	oversize := r
	oversize.ExpectedGroupRevision = 1
	oversize.MemberPaneIDs = make([]string, communicationMaxGroupMembers+1)
	if _, err := communicationGroupOperation(root, "node", oversize, known); err == nil {
		t.Fatal("member bound bypass")
	}
}

func TestCommunicationGroupStoredIdentityMustMatchPath(t *testing.T) {
	root, r, known := groupFixture(t)
	result, err := communicationGroupOperation(root, "node", r, known)
	if err != nil {
		t.Fatal(err)
	}
	group := result["group"].(communicationGroup)
	group.ID = testGroupA
	if err := communicationAtomic(filepath.Join(root, "group-"+testGroupID+".json"), group); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationGroupOperation(root, "node", CommunicationRequest{Operation: "group_get", GroupID: testGroupID}, nil); err == nil {
		t.Fatal("mismatched stored group identity accepted")
	}
	if _, err := communicationGroupOperation(root, "node", CommunicationRequest{Operation: "group_list"}, nil); err == nil {
		t.Fatal("catalogue ignored group/path mismatch")
	}
}
