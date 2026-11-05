package agentaccounts

import (
 "fmt"
 "os"
 "path/filepath"
 "testing"
)

func TestReviewerRenameFallbackDoesNotReplaceConcurrentEmptyFolder(t *testing.T) {
 root:=t.TempDir()
 for i:=0;i<20000;i++ {
  from,to:=filepath.Join(root,fmt.Sprintf("from-%d",i)),filepath.Join(root,fmt.Sprintf("to-%d",i))
  if err:=os.Mkdir(from,0700);err!=nil{t.Fatal(err)}
  gate:=make(chan struct{})
  created:=make(chan error,1)
  go func(){<-gate;created<-os.Mkdir(to,0700)}()
  close(gate)
  moved:=renameChecked(from,to)
  made:=<-created
  if moved==nil&&made==nil {
   t.Fatalf("iteration %d: concurrent Mkdir and renameChecked both succeeded; the empty recreated folder was replaced",i)
  }
  // These are empty synthetic directories inside t.TempDir.
  _=os.Remove(from);_=os.Remove(to)
 }
}
