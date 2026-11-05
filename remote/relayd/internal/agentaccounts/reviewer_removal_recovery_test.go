package agentaccounts

import (
 "bufio"
 "context"
 "errors"
 "os"
 "os/exec"
 "path/filepath"
 "strings"
 "io"
 "testing"
 "time"
)

// A crash after sign-out must not bypass the last live-user check.
func TestReviewerRecoveryDoesNotArchiveAFolderHeldByAProcess(t *testing.T) {
 home, registry, root := removeFixture(t)
 writeFile(t, filepath.Join(root,"original-data"),"original")
 original:=removeCrash
 t.Cleanup(func(){removeCrash=original})
 removeCrash=func(step string)bool{return step=="signed_out"}
 logoutRunner=func(context.Context,string,string)error{return nil}
 if _,_,err:=Remove(home,registry,"claude","personal",time.Now());!errors.Is(err,errRemovalCrashed){t.Fatal(err)}
 removeCrash=original
 staged:=stagedFolders(t,root)
 if len(staged)!=1{t.Fatal(staged)}
 pid:=startHolder(t,"HOME="+home,"RELAY_REMOVAL_HOLDER="+staged[0])
 if got,err:=liveUsers("claude",root,staged[0]);err!=nil||got==""{t.Fatalf("holder %d invisible: %q %v",pid,got,err)}
 notes:=RecoverRemovals(home)
 t.Logf("recovery notes: %v; retired: %v",notes,retiredFolders(t,home))
 if !present(staged[0])||len(retiredFolders(t,home))!=0||pendingCount(t,home)!=1 {
  t.Error("recovery archived an account folder while a known live process still held it open")
 }
}

// Pause the real AdmitLaunch immediately before exec. A missing folder
// cannot be held open; the launcher still admits it with the account variable.
func TestReviewerMissingRootLaunchHelper(t *testing.T) {
 if os.Getenv("REVIEWER_MISSING_ROOT_HELPER")!="1"{return}
 root:=os.Getenv("CLAUDE_CONFIG_DIR")
 if err:=AdmitLaunch(os.Getenv("HOME"),"claude",root);err!=nil{os.Exit(3)}
 os.Stdout.WriteString("ready\n")
 _,_=io.Copy(io.Discard,os.Stdin)
 os.Exit(0)
}

// No directory to move does not mean there is no running user.
func TestReviewerRemovalChecksLiveUsersWhenTheAccountFolderIsMissing(t *testing.T) {
 home,registry,root:=removeFixture(t)
 if err:=os.Remove(root);err!=nil{t.Fatal(err)}
 child:=exec.Command(os.Args[0],"-test.run=^TestReviewerMissingRootLaunchHelper$")
 child.Env=[]string{"HOME="+home,"CLAUDE_CONFIG_DIR="+root,"REVIEWER_MISSING_ROOT_HELPER=1"}
 out,e:=child.StdoutPipe();if e!=nil{t.Fatal(e)}
 input,e:=child.StdinPipe();if e!=nil{t.Fatal(e)}
 if e=child.Start();e!=nil{t.Fatal(e)}
 t.Cleanup(func(){_=input.Close();_=child.Process.Kill();_=child.Wait()})
 if line,e:=bufio.NewReader(out).ReadString('\n');e!=nil||line!="ready\n"{t.Fatal("helper did not start")}
 if got,e:=liveUsers("claude",root);e!=nil||got==""{t.Fatalf("admitted helper invisible: %q %v",got,e)}
 _,_,err:=Remove(home,registry,"claude","personal",time.Now())
 t.Logf("visible admitted helper pid=%d; removal=%v; registered=%v",child.Process.Pid,err,registered(t,home))
 if err==nil||!registered(t,home){t.Error("removal succeeded while an already-admitted launch was alive but had no folder handle")}
}

// A failed put-back after successful sign-out is not a pre-sign-out crash.
func TestReviewerRecoveryDoesNotRetireAfterAPostSignOutPutBack(t *testing.T) {
 home,registry,root:=removeFixture(t)
 originalUsers,originalCrash:=accountUsers,removeCrash
 t.Cleanup(func(){accountUsers=originalUsers;removeCrash=originalCrash})
 calls:=0
 accountUsers=func(string,...string)(string,error){calls++;if calls==2{return "4242",nil};return "",nil}
 logoutRunner=func(context.Context,string,string)error{
  // Make Save fail after putBack, while keeping the actual registry recoverable.
  return os.Chmod(Path(home),0666)
 }
 _,_,err:=Remove(home,registry,"claude","personal",time.Now())
 if err==nil||!strings.Contains(err.Error(),"slot will be restored"){t.Fatalf("wrong setup %v",err)}
 if err:=os.Chmod(Path(home),0600);err!=nil{t.Fatal(err)}
 notes:=RecoverRemovals(home)
 t.Logf("notes after signed-out rollback: %v",notes)
 if !registered(t,home)||!present(root){t.Fatal("failed rollback did not recover")}
}
