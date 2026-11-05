package daemon

import (
 "os"
 "path/filepath"
 "testing"
)

// A day count above time.Duration's range must never wrap into a shorter
// deletion window. Exercise the public parser and both persistent inputs.
func TestReviewerOverflowingDayRetentionRejected(t *testing.T) {
 const text="213505d" // wraps to about 24h25m with unchecked int64 nanoseconds
 t.Run("explicit parser",func(t *testing.T){
  if got,err:=ParseHostJobRetention(text);err==nil {t.Fatalf("overflow accepted as %s",got)}
 })
 for _,kind:=range []string{"file","environment"}{
  t.Run(kind,func(t *testing.T){
   stateDir:=t.TempDir()
   t.Setenv("RELAYD_HOST_JOB_RETENTION","")
   if kind=="file" {
    if err:=os.WriteFile(filepath.Join(stateDir,hostJobRetentionFile),[]byte(text),0600);err!=nil{t.Fatal(err)}
   } else {t.Setenv("RELAYD_HOST_JOB_RETENTION",text)}
   got:=ResolveHostJobRetention(stateDir)
   if got.Duration!=hostJobRetentionDefault || got.Source!="default" || len(got.Warnings)==0 {
    t.Fatalf("overflowed retention must fall back with a warning: %+v",got)
   }
  })
 }
}
