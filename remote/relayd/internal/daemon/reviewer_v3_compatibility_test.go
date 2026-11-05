package daemon

import (
 "os"
 "testing"
 "time"
)

// A legacy producer that was observed after registration must not be treated
// as proven upgraded merely because its most recent creation has aged out.
// No process or legacy binary runs; this exercises only metadata classification.
func TestReviewerObservedUnawareServerDoesNotBecomeSafeByAge(t *testing.T) {
 s:=&Server{stateDir:t.TempDir()}
 now:=time.Now()
 if err:=s.registerHostJobServer(now.Add(-20*24*time.Hour));err!=nil{t.Fatal(err)}
 old:=finishedJob("job-legacy-observed",now.Add(-9*24*time.Hour),0)
 old.Ledger=0
 writeLiveJob(t,s.stateDir,old)
 archived:=finishedJob("job-deletion-target",now.Add(-10*24*time.Hour),0)
 folder:=writeArchivedJob(t,s.stateDir,archived)
 result,err:=cleanupArchivedHostJobs(s.stateDir,s.hostJobTombstones(),HostJobCleanupOptions{OlderThan:hostJobRetentionDefault,Wait:time.Second},now,nil)
 if err==nil || result.Removed!=0 {t.Fatalf("cleanup accepted known legacy production after evidence aged out: %+v err=%v",result,err)}
 if _,err:=os.Stat(folder);err!=nil{t.Fatalf("target not preserved: %v",err)}
}
