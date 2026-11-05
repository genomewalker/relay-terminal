package appupdate

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

const receiptVersion = 2

type Baseline struct {
	Version    int               `json:"version"`
	Identities map[string]string `json:"identities"`
	Panes      []string          `json:"panes"`
	Workspace  map[string]any    `json:"workspace"`
	Authority  string            `json:"workspaceAuthority"`
	Installed  map[string]string `json:"installedHashes"`
	Staged     map[string]string `json:"stagedHashes"`
}
type QuitState struct {
	Workspace map[string]any    `json:"workspace"`
	Authority string            `json:"workspaceAuthority"`
	Drafts    map[string]string `json:"drafts"`
	Callers   any               `json:"callers"`
}
type StageOptions struct {
	Candidate                string
	UIClosed, WorkspaceTools bool
}

func (e *Engine) baseline(root string) (Baseline, error) {
	var b Baseline
	raw, err := readPrivate(filepath.Join(root, "baseline.json"), e.Config.UID)
	if err != nil {
		return b, err
	}
	if err = decodeRecord(raw, &b); err != nil {
		return b, err
	}
	if b.Version != receiptVersion || len(b.Panes) == 0 || len(b.Identities) == 0 || b.Installed["Contents/MacOS/Relay"] == "" || b.Staged["Contents/MacOS/Relay"] == "" {
		return b, errors.New("invalid or incompatible native receipt")
	}
	if b.Authority != "shared" && b.Authority != "preferences" {
		return b, errors.New("invalid workspace authority")
	}
	return b, nil
}
func (e *Engine) copy(args ...string) error {
	_, err := e.command(0, append([]string{"/bin/cp"}, args...)...)
	return err
}
func (e *Engine) backupPreferences(root, name string) error {
	if err := e.copy(e.preferences(), filepath.Join(root, name)); err != nil {
		return err
	}
	return os.Chmod(filepath.Join(root, name), 0600)
}
func (e *Engine) Stage(o StageOptions) (map[string]any, error) {
	candidate, err := absolute(o.Candidate)
	if err != nil {
		return nil, err
	}
	root, err := os.MkdirTemp(e.Config.TempRoot, "relay-interface-update-")
	if err != nil {
		return nil, err
	}
	done := false
	defer func() {
		if !done {
			os.RemoveAll(root)
		}
	}()
	if err = e.signature(candidate); err != nil {
		return nil, err
	}
	if err = e.signature(e.Config.Installed); err != nil {
		return nil, err
	}
	prefs, err := e.plist(e.preferences())
	if err != nil {
		return nil, err
	}
	workspace, authority, err := e.workspace(prefs, "")
	if err != nil {
		return nil, err
	}
	expected, err := WorkspaceIDs(workspace)
	if err != nil {
		return nil, err
	}
	if o.UIClosed {
		pids, err := e.AppPIDs(e.Config.Installed)
		if err != nil {
			return nil, err
		}
		if len(pids) != 0 {
			return nil, errors.New("UI must be closed")
		}
	} else {
		live, err := e.state()
		if err != nil {
			return nil, err
		}
		panes, err := PaneIDs(live)
		if err != nil {
			return nil, err
		}
		if !sameStrings(panes, expected) {
			return nil, errors.New("live panes differ from workspace")
		}
		focus, err := LiveFocus(live)
		if err != nil {
			return nil, err
		}
		if !equal(NormalizedFocus(focus), NormalizedFocus(workspace)) {
			return nil, errors.New("saved focus differs from live workspace")
		}
	}
	staged := filepath.Join(root, "Relay.app")
	if err = e.copy("-cR", candidate, staged); err != nil {
		return nil, err
	}
	if _, err = e.command(0, "/usr/bin/xattr", "-cr", staged); err != nil {
		return nil, err
	}
	if err = e.signature(staged); err != nil {
		return nil, err
	}
	old, err := Hashes(e.Config.Installed)
	if err != nil {
		return nil, err
	}
	next, err := Hashes(staged)
	if err != nil {
		return nil, err
	}
	source, err := Hashes(candidate)
	if err != nil {
		return nil, err
	}
	if len(source) != len(next) {
		return nil, errors.New("candidate clone file set changed")
	}
	for k, h := range source {
		n, ok := next[k]
		if !ok || !strings.Contains(k, "/_CodeSignature/") && h != n {
			return nil, errors.New("candidate clone bytes changed")
		}
	}
	info, err := e.plist(filepath.Join(candidate, "Contents/Info.plist"))
	if err != nil {
		return nil, err
	}
	if info["CFBundleIdentifier"] != "dev.relay.terminal" {
		return nil, errors.New("candidate is not Relay")
	}
	for _, k := range []string{"RelayStateRoot", "RelayDefaultsSuite", "RelaySidePanelPort"} {
		if _, ok := info[k]; ok {
			return nil, errors.New("candidate contains isolated state override")
		}
	}
	if err = e.backupPreferences(root, "before-preferences.plist"); err != nil {
		return nil, err
	}
	identities, err := e.identities()
	if err != nil {
		return nil, err
	}
	baseline := Baseline{receiptVersion, identities, expected, workspace, authority, old, next}
	if err = writeRecord(filepath.Join(root, "baseline.json"), baseline); err != nil {
		return nil, err
	}
	done = true
	return map[string]any{"root": root, "panes": len(expected), "staged": true, "fullBundle": true, "receiptVersion": receiptVersion}, nil
}
func (e *Engine) callers() (any, error) {
	p := filepath.Join(e.support(), "caller-control-v1.json")
	raw, err := readBound(p)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return object(raw)
}
func (e *Engine) Apply(path string) (map[string]any, error) { return e.apply(path, false) }
func (e *Engine) apply(path string, globalHeld bool) (map[string]any, error) {
	if !globalHeld {
		guard, err := lockFile(e.globalLock(), e.Config.UID)
		if err != nil {
			return nil, err
		}
		defer guard.Close()
	}
	root, err := e.receiptRoot(path)
	if err != nil {
		return nil, err
	}
	lock, err := lockFile(filepath.Join(root, "lock"), e.Config.UID)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	baseline, err := e.baseline(root)
	if err != nil {
		return nil, err
	}
	if err = e.retained(baseline.Identities); err != nil {
		return nil, err
	}
	pids, err := e.AppPIDs(e.Config.Installed)
	if err != nil {
		return nil, err
	}
	if len(pids) != 0 {
		return nil, errors.New("quit the native UI normally before applying")
	}
	old, err := Hashes(e.Config.Installed)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(old, baseline.Installed) {
		return nil, errors.New("installed bundle changed since staging")
	}
	staged := filepath.Join(root, "Relay.app")
	next, err := Hashes(staged)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(next, baseline.Staged) {
		return nil, errors.New("staged bundle changed")
	}
	if err = e.signature(staged); err != nil {
		return nil, err
	}
	for _, name := range []string{"previous-Relay.app", "failed-Relay.app", "quit-state.json", "applied.json"} {
		if _, x := os.Lstat(filepath.Join(root, name)); x == nil {
			return nil, errors.New("receipt already used: " + name)
		} else if !os.IsNotExist(x) {
			return nil, x
		}
	}
	prefs, err := e.plist(e.preferences())
	if err != nil {
		return nil, err
	}
	workspace, authority, err := e.workspace(prefs, baseline.Authority)
	if err != nil {
		return nil, err
	}
	panes, err := WorkspaceIDs(workspace)
	if err != nil {
		return nil, err
	}
	if !sameStrings(panes, baseline.Panes) {
		return nil, errors.New("saved panes changed")
	}
	for _, name := range []string{"AgentState", "AgentDrafts", "NativeCodex", "OwnedSessions", "TerminalSnapshots"} {
		src := filepath.Join(e.support(), name)
		if _, x := os.Stat(src); x == nil {
			if err = e.copy("-cR", src, filepath.Join(root, name)); err != nil {
				return nil, err
			}
		} else if !os.IsNotExist(x) {
			return nil, x
		}
	}
	if err = e.backupPreferences(root, "quit-preferences.plist"); err != nil {
		return nil, err
	}
	drafts, err := Hashes(filepath.Join(e.support(), "AgentDrafts"))
	if err != nil {
		return nil, err
	}
	callers, err := e.callers()
	if err != nil {
		return nil, err
	}
	if err = writeRecord(filepath.Join(root, "quit-state.json"), QuitState{workspace, authority, drafts, callers}); err != nil {
		return nil, err
	}
	// Recheck both complete bundles immediately before the replacement boundary.
	old, err = Hashes(e.Config.Installed)
	if err != nil {
		return nil, err
	}
	next, err = Hashes(staged)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(old, baseline.Installed) || !reflect.DeepEqual(next, baseline.Staged) {
		return nil, errors.New("bundle changed before replacement")
	}
	previous := filepath.Join(root, "previous-Relay.app")
	if err = os.Rename(e.Config.Installed, previous); err != nil {
		return nil, err
	}
	rollback := func(cause error) error {
		if _, x := os.Lstat(e.Config.Installed); x == nil {
			if x = os.Rename(e.Config.Installed, filepath.Join(root, "failed-Relay.app")); x != nil {
				return fmt.Errorf("%w; rollback quarantine failed: %v", cause, x)
			}
		}
		if x := os.Rename(previous, e.Config.Installed); x != nil {
			return fmt.Errorf("%w; rollback restore failed: %v", cause, x)
		}
		return cause
	}
	if _, err = e.command(0, "/usr/bin/ditto", staged, e.Config.Installed); err != nil {
		return nil, rollback(err)
	}
	if err = e.signature(e.Config.Installed); err != nil {
		return nil, rollback(err)
	}
	installed, err := Hashes(e.Config.Installed)
	if err != nil {
		return nil, rollback(err)
	}
	if !reflect.DeepEqual(installed, baseline.Staged) {
		return nil, rollback(errors.New("installed bundle differs from staged bytes"))
	}
	if err = e.retained(baseline.Identities); err != nil {
		return nil, rollback(err)
	}
	result := map[string]any{"fullBundle": true, "kernelIdentitiesRetained": len(baseline.Identities)}
	if err = writeRecord(filepath.Join(root, "applied.json"), result); err != nil {
		return nil, rollback(err)
	}
	if err = syncDirectory(filepath.Dir(e.Config.Installed)); err != nil {
		return nil, err
	}
	return result, nil
}
func (e *Engine) Verify(path string) (map[string]any, error) {
	guard, err := lockFile(e.globalLock(), e.Config.UID)
	if err != nil {
		return nil, err
	}
	defer guard.Close()
	root, err := e.receiptRoot(path)
	if err != nil {
		return nil, err
	}
	lock, err := lockFile(filepath.Join(root, "lock"), e.Config.UID)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	baseline, err := e.baseline(root)
	if err != nil {
		return nil, err
	}
	if err = e.retained(baseline.Identities); err != nil {
		return nil, err
	}
	if err = e.signature(e.Config.Installed); err != nil {
		return nil, err
	}
	hashes, err := Hashes(e.Config.Installed)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(hashes, baseline.Staged) {
		return nil, errors.New("installed bundle differs from receipt")
	}
	current, err := e.state()
	if err != nil {
		return nil, err
	}
	panes, err := PaneIDs(current)
	if err != nil {
		return nil, err
	}
	if !sameStrings(panes, baseline.Panes) {
		return nil, errors.New("live panes changed")
	}
	raw, err := readPrivate(filepath.Join(root, "quit-state.json"), e.Config.UID)
	if err != nil {
		return nil, err
	}
	var quit QuitState
	if err = decodeRecord(raw, &quit); err != nil {
		return nil, err
	}
	prefs, err := e.plist(e.preferences())
	if err != nil {
		return nil, err
	}
	workspace, authority, err := e.workspace(prefs, quit.Authority)
	if err != nil {
		return nil, err
	}
	beforeLayout, err := Layout(quit.Workspace)
	if err != nil {
		return nil, err
	}
	afterLayout, err := Layout(workspace)
	if err != nil {
		return nil, err
	}
	if !equal(beforeLayout, afterLayout) {
		return nil, errors.New("saved layout changed")
	}
	drafts, err := Hashes(filepath.Join(e.support(), "AgentDrafts"))
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(drafts, quit.Drafts) {
		return nil, errors.New("drafts changed")
	}
	callers, err := e.callers()
	if err != nil {
		return nil, err
	}
	if err = AuditContinuity(quit.Callers, callers); err != nil {
		return nil, err
	}
	if err = e.retained(baseline.Identities); err != nil {
		return nil, err
	}
	focus, err := LiveFocus(current)
	if err != nil {
		return nil, err
	}
	focusFields := func(m map[string]any) map[string]any {
		return map[string]any{"selectedTabID": m["selectedTabID"], "activePaneID": m["activePaneID"]}
	}
	result := map[string]any{"panesRetained": len(baseline.Panes), "processKernelIdentitiesRetained": len(baseline.Identities), "layoutRetained": true, "draftsRetained": true, "callerRegistryAndAuditRetained": true, "signedInterfaceInstalled": true, "focusBeforeUpdate": focusFields(quit.Workspace), "workspaceAuthority": authority, "focusAtVerification": focus, "savedFocusAtVerification": focusFields(workspace), "focusRetained": equal(NormalizedFocus(quit.Workspace), NormalizedFocus(focus)), "savedFocusMatchesLive": equal(NormalizedFocus(workspace), NormalizedFocus(focus))}
	if err = writeRecord(filepath.Join(root, "verified.json"), result); err != nil {
		return nil, err
	}
	return result, nil
}
