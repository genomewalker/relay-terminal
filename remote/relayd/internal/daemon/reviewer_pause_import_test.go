package daemon

import (
    "crypto/sha256"
    "encoding/hex"
    "strings"
    "testing"
)

// Another client's authoritative server pause must survive a stale desktop
// import. This uses an isolated policy record, no real caller or host state.
func TestReviewerStaleImportCannotUndoAnotherClientsPause(t *testing.T) {
    root := t.TempDir()
    token := "synthetic-review-client"
    digest := sha256.Sum256([]byte(token))
    caller := communicationCaller{ID:"11111111-2222-4333-8444-555555555555",Label:"Fixture",TokenHash:hex.EncodeToString(digest[:]),Paused:true}
    if err := communicationAtomic(communicationPolicyPath(root),communicationPolicy{Callers:[]communicationCaller{caller}}); err != nil { t.Fatal(err) }
    caller.Paused = false
    stale := communicationPolicy{Callers:[]communicationCaller{caller}}
    if _,err := communicationPolicyAdmin(root,CommunicationRequest{Operation:"caller_policy_import",Policy:&stale}); err != nil { t.Fatal(err) }
    if _,err := communicationAuthorize(root,CommunicationRequest{Operation:"send",ClientToken:token}); err == nil || !strings.Contains(err.Error(),"paused") {
        t.Fatalf("stale client import removed another client's server pause: %v",err)
    }
}
