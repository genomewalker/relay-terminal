package daemon

import (
 "os"
 "path/filepath"
 "testing"
 "time"
)

// Daemons sharing a state directory keep separate in-memory maps and mutexes.
// An hourly pass by one must not break the other's completed-job output reads.
func TestReviewerOtherDaemonArchivePreservesTrackedStatus(t *testing.T) {
 stateDir:=t.TempDir()
 owner:=&Server{stateDir:stateDir}
 archiver:=&Server{stateDir:stateDir}
 now:=time.Now()
 record:=finishedJob("job-other-daemon",now.Add(-time.Hour),3)
 directory:=writeLiveJob(t,stateDir,record)
 for name,body:=range map[string]string{"stdout":"output of "+record.JobID,"stderr":""}{
  if err:=os.WriteFile(filepath.Join(directory,name),[]byte(body),0600);err!=nil{t.Fatal(err)}
 }
 owner.hostJobs.Store(record.JobID,&hostJob{record:record,directory:directory})
 request:=hostRequest{RequestID:"status",Operation:"status",JobID:record.JobID}
 if _,err:=owner.hostRPC(request);err!=nil {t.Fatalf("before archive: %v",err)}
 result,err:=archiver.archiveAndCleanupHostJobs(now)
 if err!=nil || result.Archived!=1 || !result.CleanupInactive || result.Removed!=0 {
  t.Fatalf("inactive archive pass: %+v %v",result,err)
 }
 value,err:=owner.hostRPC(request)
 if err!=nil {t.Fatalf("a different daemon archived the folder and broke tracked status: %v",err)}
 snapshot:=value.(map[string]any)
 if snapshot["output_expired"]==true || string(snapshot["stdout"].([]byte))!="output of "+record.JobID {
  t.Fatalf("archiving lost retained output: %+v",snapshot)
 }
}
