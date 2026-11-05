package main
import("bytes";"os";"path/filepath";"strings";"sync";"testing")
// The observer creates a user profile only after Relay's temporary file
// appears, so the initial destination check has already completed.
func TestReviewerConcurrentUserProfileMustSurvive(t *testing.T) {
 for attempt:=0;attempt<200;attempt++ {
  dir:=t.TempDir(); path:=filepath.Join(dir,"relay-terminal.config.toml"); user:=[]byte("# user-authored profile\nmodel = \"preserve-me\"\n")
  stop:=make(chan struct{}); wrote:=make(chan bool,1);var wg sync.WaitGroup;wg.Add(1)
  go func(){defer wg.Done();for {select {case <-stop:return;default:}
   entries,_:=os.ReadDir(dir);for _,e:=range entries {if strings.HasPrefix(e.Name(),".relay-terminal-") {
    f,err:=os.OpenFile(path,os.O_CREATE|os.O_EXCL|os.O_WRONLY,0600);if err!=nil {wrote<-false;return};_,err=f.Write(user);closeErr:=f.Close();wrote<-(err==nil&&closeErr==nil);return
   }}
  }}()
  status,_,err:=ensureCodexRelayProfile(dir,dir);close(stop);wg.Wait()
  select {case created:=<-wrote:if created {got,readErr:=os.ReadFile(path);if readErr!=nil||!bytes.Equal(got,user){t.Fatalf("user profile overwritten after initial check: attempt=%d status=%q err=%v bytes=%d readErr=%v",attempt,status,err,len(got),readErr)};t.Log("observed concurrent creation and preservation");return};default:}
 }
 t.Skip("no concurrent creation observed; race inconclusive")
}
