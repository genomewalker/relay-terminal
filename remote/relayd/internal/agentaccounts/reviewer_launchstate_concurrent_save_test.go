package agentaccounts

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Observe the real temporary file created by writeAtomic, which happens
// only AFTER sameContent has returned true. Save provider state while that
// temporary file is being written/fsynced, before Relay renames it.
// Production code is unmodified; the existing before-read-check hook only
// starts the observer. All files and provider state are synthetic.
func TestReviewerLaunchMergePreservesSaveAfterContentCheck(t *testing.T) {
	home, account, path := launchStateFixture(t, `{"userID":"account","numStartups":1,"padding":"`+strings.Repeat("x", 8<<20)+`"}`)
	live := []byte(`{"userID":"account","numStartups":99,"providerNewState":"keep-me"}`)
	liveTemp := filepath.Join(account.Root(home), ".provider-save")
	if err := os.WriteFile(liveTemp, live, 0600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	original := beforeLaunchStateWrite
	t.Cleanup(func() { beforeLaunchStateWrite = original })
	beforeLaunchStateWrite = func(_ string) {
		go func() {
			deadline := time.Now().Add(5 * time.Second)
			for time.Now().Before(deadline) {
				matches, err := filepath.Glob(filepath.Join(account.Root(home), ".relay-account-*"))
				if err != nil {
					done <- err
					return
				}
				if len(matches) > 0 {
					if err := os.Rename(liveTemp, path); err != nil {
						done <- err
						return
					}
					if _, err := os.Stat(matches[0]); err != nil {
						done <- fmt.Errorf("timing inconclusive: Relay temp gone after provider save: %w", err)
						return
					}
					done <- nil
					return
				}
				time.Sleep(100 * time.Microsecond)
			}
			done <- fmt.Errorf("no Relay atomic-write temporary file observed")
		}()
	}
	state, _, err := mergeLaunchState(home, account)
	if observerErr := <-done; observerErr != nil {
		t.Fatal(observerErr)
	}
	if err != nil {
		t.Logf("merge safely refused: %v", err)
	}
	var after map[string]json.RawMessage
	if err := json.Unmarshal(mustRead(t, path), &after); err != nil {
		t.Fatal(err)
	}
	if string(after["numStartups"]) != "99" || string(after["providerNewState"]) != `"keep-me"` {
		t.Fatalf("provider save made AFTER content check was overwritten: merge=%s err=%v numStartups=%s providerNewState=%s", state, err, after["numStartups"], after["providerNewState"])
	}
}
