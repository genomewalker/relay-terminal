package agentaccounts

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// providerSave stands in for Claude saving its file: a complete file renamed
// over the path, as Claude Code's atomic write does.
func providerSave(t *testing.T, path, content string) {
	t.Helper()
	temp := path + ".provider-save"
	if err := os.WriteFile(temp, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(temp, path); err != nil {
		t.Fatal(err)
	}
}

func noRelayTemps(t *testing.T, path string) {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".relay-account-*"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("temporary files left: %v %v", matches, err)
	}
}

func swapSeams(t *testing.T) {
	t.Helper()
	exchange, after, busy := launchStateExchange, afterLaunchStateSwap, launchStateBusy
	t.Cleanup(func() { launchStateExchange, afterLaunchStateSwap, launchStateBusy = exchange, after, busy })
}

const accountState = `{"userID":"account","numStartups":1}`

func TestLaunchStateSwapMergesAnUnchangedFile(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, accountState)
	swaps := 0
	launchStateExchange = func(a, b string) (bool, error) { swaps++; return renameExchange(a, b) }
	state, added, err := mergeLaunchState(home, account)
	if state != LaunchStateUpdated || added == 0 || err != nil || swaps != 1 {
		t.Fatalf("state=%s added=%d err=%v swaps=%d", state, added, err, swaps)
	}
	document := jsonObject(t, path)
	if string(document["numStartups"]) != "1" || string(document["hasCompletedOnboarding"]) != "true" {
		t.Fatalf("merge result: %v", document)
	}
	noRelayTemps(t, path)
}

func TestLaunchStateKeepsASaveThatLandsBetweenTheSwapAndItsVerification(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, accountState)
	saved := `{"userID":"account","numStartups":99}`
	afterLaunchStateSwap = func(string) { providerSave(t, path, saved) }
	state, _, err := mergeLaunchState(home, account)
	if state != LaunchStateRefused || !errors.Is(err, errConcurrentSave) {
		t.Fatalf("state=%s err=%v", state, err)
	}
	if got := string(mustRead(t, path)); got != saved {
		t.Fatalf("the provider's save was not kept: %s", got)
	}
	noRelayTemps(t, path)
}

func TestLaunchStateSwapsBackASaveThatLandsBeforeTheSwap(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, accountState)
	saved := `{"userID":"account","numStartups":99,"providerNewState":"keep-me"}`
	swaps := 0
	launchStateExchange = func(a, b string) (bool, error) {
		swaps++
		if swaps == 1 {
			providerSave(t, path, saved)
		}
		return renameExchange(a, b)
	}
	state, _, err := mergeLaunchState(home, account)
	if state != LaunchStateRefused || !errors.Is(err, errConcurrentSave) || swaps != 2 {
		t.Fatalf("state=%s err=%v swaps=%d", state, err, swaps)
	}
	if got := string(mustRead(t, path)); got != saved {
		t.Fatalf("the provider's save was not restored: %s", got)
	}
	noRelayTemps(t, path)
}

func TestLaunchStateRestoresTheNewestOfRepeatedSaves(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, accountState)
	first, second := `{"userID":"account","numStartups":2}`, `{"userID":"account","numStartups":3}`
	swaps := 0
	launchStateExchange = func(a, b string) (bool, error) {
		swaps++
		switch swaps {
		case 1:
			providerSave(t, path, first)
		case 2:
			// A second save replaces the merged copy before Relay swaps the first back.
			providerSave(t, path, second)
		}
		return renameExchange(a, b)
	}
	state, _, err := mergeLaunchState(home, account)
	if state != LaunchStateRefused || !errors.Is(err, errConcurrentSave) || swaps != 3 {
		t.Fatalf("state=%s err=%v swaps=%d", state, err, swaps)
	}
	if got := string(mustRead(t, path)); got != second {
		t.Fatalf("the newest save is not at the path: %s", got)
	}
	noRelayTemps(t, path)
}

func TestLaunchStateKeepsADisplacedSaveWhenSwappingBackFails(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, accountState)
	saved := `{"userID":"account","numStartups":99}`
	swaps := 0
	launchStateExchange = func(a, b string) (bool, error) {
		swaps++
		if swaps == 1 {
			providerSave(t, path, saved)
			return renameExchange(a, b)
		}
		return true, unix.EIO
	}
	_, _, err := mergeLaunchState(home, account)
	if err == nil {
		t.Fatal("a failed swap-back was reported as success")
	}
	matches, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".relay-account-*"))
	if len(matches) != 1 || string(mustRead(t, matches[0])) != saved {
		t.Fatalf("the displaced save was not kept: %v (%v)", matches, err)
	}
}

func TestLaunchStateWithoutAtomicExchangeSkipsAnExistingFileBusyOrIdle(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, accountState)
	launchStateExchange = func(string, string) (bool, error) { return false, unix.EINVAL }
	for _, busy := range []error{errors.New("busy"), nil} {
		asked := 0
		launchStateBusy = func(string, string) error { asked++; return busy }
		state, added, err := mergeLaunchState(home, account)
		if state != LaunchStateSkipped || added != 0 || err == nil ||
			!strings.Contains(err.Error(), "atomic exchange unsupported on this filesystem; merge skipped") {
			t.Fatalf("busy=%v: state=%s added=%d err=%v", busy, state, added, err)
		}
		// Whether an agent runs decides nothing: no check keeps it from saving.
		if asked != 0 || string(mustRead(t, path)) != accountState {
			t.Fatalf("busy=%v: busy asked %d times; file=%s", busy, asked, mustRead(t, path))
		}
		noRelayTemps(t, path)
	}
}

func TestLaunchStateWithoutAtomicExchangeStillCreatesAMissingFile(t *testing.T) {
	swapSeams(t)
	home, account, path := launchStateFixture(t, "")
	launchStateExchange = func(string, string) (bool, error) { t.Fatal("exchange used to create a file"); return false, nil }
	state, added, err := mergeLaunchState(home, account)
	if state != LaunchStateUpdated || added == 0 || err != nil {
		t.Fatalf("state=%s added=%d err=%v", state, added, err)
	}
	if string(jsonObject(t, path)["hasCompletedOnboarding"]) != "true" {
		t.Fatal("the missing file was not created with the first-run answers")
	}
	noRelayTemps(t, path)
}

// The companion of the reviewer's unsupported-exchange fixture. Its observer
// starts before the read check and watches Relay's .relay-account-* files:
// the first is the exchange probe; any later one is a replacement written
// after every check, and the provider saves then (99, keep-me). Without
// atomic exchange there must be no such write, the busy check must not be
// consulted, and the merge is skipped; with the idle fallback restored the
// save lands in that write and must still be at the path.
func TestLaunchStateWithoutAtomicExchangeKeepsASaveMadeAfterEveryCheck(t *testing.T) {
	swapSeams(t)
	before := beforeLaunchStateWrite
	t.Cleanup(func() { beforeLaunchStateWrite = before })
	home, account, path := launchStateFixture(t, `{"userID":"account","numStartups":1,"padding":"`+strings.Repeat("x", 8<<20)+`"}`)
	saved := `{"userID":"account","numStartups":99,"providerNewState":"keep-me"}`
	original := string(mustRead(t, path))
	launchStateExchange = func(string, string) (bool, error) { return false, unix.EINVAL }
	asked := false
	launchStateBusy = func(string, string) error { asked = true; return nil }
	stop, observed := make(chan struct{}), make(chan []string, 1)
	beforeLaunchStateWrite = func(string) {
		go func() {
			var seen []string
			defer func() { observed <- seen }()
			for {
				select {
				case <-stop:
					return
				default:
				}
				matches, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".relay-account-*"))
				for _, name := range matches {
					if len(seen) == 0 || seen[len(seen)-1] != name {
						seen = append(seen, name)
						if len(seen) > 1 {
							providerSave(t, path, saved)
						}
					}
				}
				time.Sleep(50 * time.Microsecond)
			}
		}()
	}
	state, _, err := mergeLaunchState(home, account)
	close(stop)
	seen := <-observed
	got := string(mustRead(t, path))
	if len(seen) > 1 && got != saved {
		t.Fatalf("a save made after every check was overwritten: state=%s err=%v writes=%d", state, err, len(seen))
	}
	if asked || len(seen) > 1 {
		t.Fatalf("the idle fallback ran: busy asked=%v, Relay files after the probe=%d, state=%s", asked, len(seen)-1, state)
	}
	if state != LaunchStateSkipped || err == nil || got != original {
		t.Fatalf("state=%s err=%v; the file changed=%v", state, err, got != original)
	}
	noRelayTemps(t, path)
}

func TestRenameExchangeSwapsTwoFiles(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	writeFile(t, a, "A")
	writeFile(t, b, "B")
	if supported, err := renameExchange(a, b); !supported {
		t.Skipf("no atomic exchange on this file system: %v", err)
	} else if err != nil {
		t.Fatal(err)
	}
	if string(mustRead(t, a)) != "B" || string(mustRead(t, b)) != "A" {
		t.Fatal("files were not exchanged")
	}
}
