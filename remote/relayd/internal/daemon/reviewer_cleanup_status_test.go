package daemon

import (
    "testing"
    "time"
)

// A long-lived daemon retains completed jobs in its map, including those
// moved into the archive. Cleanup must serve their tombstone status too.
func TestReviewerTrackedArchivedJobReportsExpiredAfterCleanup(t *testing.T) {
    s := &Server{stateDir:t.TempDir()}
    now := time.Now()
    record := finishedJob("job-tracked-expired",now.Add(-8*24*time.Hour),3)
    directory := writeArchivedJob(t,s.stateDir,record)
    s.hostJobs.Store(record.JobID,&hostJob{directory:directory,record:record})
    result,err := runCleanup(t,s,now,nil)
    if err != nil || result.Removed != 1 { t.Fatalf("cleanup %+v %v",result,err) }
    value,err := s.hostRPC(hostRequest{RequestID:"status",Operation:"status",JobID:record.JobID})
    if err != nil { t.Fatalf("tracked expired job returned an error instead of tombstone status: %v",err) }
    snapshot := value.(map[string]any)
    final := snapshot["job"].(hostJobRecord)
    if snapshot["output_expired"] != true || final.ExitCode == nil || *final.ExitCode != 3 {
        t.Fatalf("tracked expired status lost its final result: %+v",snapshot)
    }
}
