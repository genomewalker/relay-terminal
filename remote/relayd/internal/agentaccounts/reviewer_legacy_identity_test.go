package agentaccounts

import (
 "os"
 "path/filepath"
 "testing"
)

// Pre-v1e journals have no original inode and no Moved field. An empty
// original may already be staged while another provider recreates root.
// This must not be interpreted as an unfilled staging reservation.
func TestReviewerLegacyJournalDoesNotDiscardAnEmptyOriginalForARecreatedRoot(t *testing.T) {
 home,registry,root:=removeFixture(t)
 account,_:=registry.Find("claude","personal")
 originalDev,originalInode,ok:=folderIdentity(root)
 if !ok{t.Fatal("fixture original has no identity")}
 job:=removal{ID:"0123456789abcdef",Account:account,Index:1,Root:root,
  Staged:filepath.Join(filepath.Dir(root),".claude-personal.removing-0123456789abcdef"),
  Destination:filepath.Join(home,"retired","claude-personal")}
 // The fields omitted by the real v1d record remain absent here.
 if err:=writeRemoval(home,job);err!=nil{t.Fatal(err)}
 kept:=Registry{Version:registryVersion}
 for _,a:=range registry.Accounts {if a.Provider!="claude"||a.Label!="personal"{kept.Accounts=append(kept.Accounts,a)}}
 if _,err:=Save(home,kept);err!=nil{t.Fatal(err)}
 if err:=os.Rename(root,job.Staged);err!=nil{t.Fatal(err)}
 writeFile(t,filepath.Join(root,"replacement-data"),"new provider state")
 notes:=RecoverRemovals(home)
 t.Logf("notes=%v; registered=%v; pending=%d",notes,registered(t,home),pendingCount(t,home))
 dev,inode,exists:=folderIdentity(job.Staged)
 if !exists||dev!=originalDev||inode!=originalInode {
  t.Error("recovery removed the original staged account inode by mistaking it for a placeholder")
 }
 if registered(t,home) {
  t.Error("recovery registered the replacement root as the original account")
 }
 if string(mustRead(t,filepath.Join(root,"replacement-data")))!="new provider state" {
  t.Error("replacement data was changed")
 }
}
