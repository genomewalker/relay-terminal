package daemon

import (
 "os"
 "path/filepath"
 "strings"
 "testing"
)

// Model a local symlink to a state directory on a different filesystem.
// The new ledger entry must be persisted in the actual state directory.
func TestReviewerCrossFilesystemStateSymlinkSyncsLedgerParent(t *testing.T) {
 root:=t.TempDir()
 dataMount:=filepath.Join(root,"data")
 state:=filepath.Join(dataMount,"state")
 localMount:=filepath.Join(root,"local")
 if err:=os.MkdirAll(state,0700);err!=nil{t.Fatal(err)}
 if err:=os.MkdirAll(localMount,0700);err!=nil{t.Fatal(err)}
 alias:=filepath.Join(localMount,"state")
 if err:=os.Symlink(state,alias);err!=nil{t.Fatal(err)}
 stateInfo,err:=os.Stat(state)
 if err!=nil{t.Fatal(err)}
 restoreDevice,restoreSync:=durableDirectoryDevice,questionJournalSync
 defer func(){durableDirectoryDevice,questionJournalSync=restoreDevice,restoreSync}()
 durableDirectoryDevice=func(path string)(uint64,error){
  // Follow production Lstat semantics, then model distinct filesystem IDs.
  info,err:=os.Lstat(path)
  if err!=nil{return 0,err}
  if info.Mode()&os.ModeSymlink!=0{return 10,nil}
  if strings.HasPrefix(path+string(os.PathSeparator),dataMount+string(os.PathSeparator)) || strings.HasPrefix(path,alias+string(os.PathSeparator)){return 20,nil}
  return 10,nil
 }
 syncedParent:=false
 var synced []string
 questionJournalSync=func(file *os.File)error{
  synced=append(synced,file.Name())
  info,err:=file.Stat()
  if err!=nil{return err}
  if os.SameFile(info,stateInfo){syncedParent=true}
  return file.Sync()
 }
 target:=filepath.Join(alias,"host-jobs-tombstones")
 if err:=durableDirectory(target);err!=nil{t.Fatal(err)}
 if !syncedParent{t.Fatalf("returned success without syncing the state directory that names the new ledger; synced=%v",synced)}
}
