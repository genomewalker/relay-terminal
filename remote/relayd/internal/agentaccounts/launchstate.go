package agentaccounts

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Claude's first-run and trust answers, copied from the main .claude.json
// into an account so a conversation started or resumed there never stops at
// a first-run screen. Only these keys are read from the main file; account
// state (oauthAccount, userID and every other key) is never copied, and a key
// the account already has is never changed.
var (
	claudeFirstRunKeys = []string{"hasCompletedOnboarding", "lastOnboardingVersion", "hasSeenTasksHint",
		"shiftEnterKeyBindingInstalled", "autoUpdates"}
	claudeProjectTrustKeys = []string{"hasTrustDialogAccepted", "hasClaudeMdExternalIncludesWarningShown",
		"hasClaudeMdExternalIncludesApproved"}
)

// Codex's first-run trust answer: [projects."<path>"] trust_level.
const codexTrustKey = "trust_level"

// LaunchState states, reported by Sync and by the launch-time merge.
const (
	LaunchStateUpdated   = "updated"
	LaunchStateUnchanged = "unchanged"
	LaunchStateNothing   = "nothing_to_merge"
	LaunchStateRefused   = "refused"
	// LaunchStateSkipped: the file exists and its file system has no atomic
	// exchange, so it is never replaced (errNoAtomicExchange).
	LaunchStateSkipped = "skipped"
)

// launchStatePlan is an account file and what the merge adds to it.
type launchStatePlan struct {
	accountPath string
	before      fileState
	data        []byte
	next        []byte
	added       int
}

// beforeLaunchStateWrite lets a test change the file between the read and
// the write; afterLaunchStateSwap, between the swap and its verification.
// launchStateBusy is no longer consulted: an idle check cannot keep an agent
// from saving, so it decides nothing. It stays a seam for earlier fixtures.
var (
	beforeLaunchStateWrite = func(path string) {}
	afterLaunchStateSwap   = func(path string) {}
	launchStateExchange    = renameExchange
	launchStateBusy        = refuseWhileRunning
)

// launchStateSwaps bounds how often a displaced provider save is swapped back.
const launchStateSwaps = 8

// errConcurrentSave reports a merge left for the next launch because the
// provider saved the file while Relay replaced it.
var errConcurrentSave = errors.New("skipped: concurrent save")

// errNoAtomicExchange: without an atomic exchange (NFS, for example) Relay
// cannot replace an existing account file without risking an agent's save,
// so it never does. Creating a missing file (link(2)) still works.
var errNoAtomicExchange = errors.New("skipped: atomic exchange unsupported on this filesystem; merge skipped")

// mergeLaunchState adds the main account's first-run and trust answers that
// the account does not have yet. It only adds: an existing value, even false,
// is kept. The account file is exchanged with the merged copy in one step and
// the displaced file is compared with what was read; if the provider saved in
// between, its save is swapped back and the merge waits for the next launch.
func mergeLaunchState(home string, account Account) (string, int, error) {
	if account.Dir == "" {
		return LaunchStateNothing, 0, nil
	}
	main, root := defaultRoot(home, account.Provider), account.Root(home)
	if err := distinctRoots(main, root); err != nil {
		return LaunchStateRefused, 0, err
	}
	if !present(root) {
		// Not created yet (Prepare does that, before the first sign-in).
		return LaunchStateNothing, 0, nil
	}
	var plan launchStatePlan
	var err error
	if account.Provider == "codex" {
		plan, err = planCodexTrust(filepath.Join(main, "config.toml"), filepath.Join(root, "config.toml"))
	} else {
		plan, err = planClaudeLaunchState(filepath.Join(home, ".claude.json"), filepath.Join(root, ".claude.json"))
	}
	if err != nil {
		return LaunchStateRefused, 0, err
	}
	if plan.next == nil {
		if plan.added == 0 && plan.before.exists {
			return LaunchStateUnchanged, 0, nil
		}
		return LaunchStateNothing, 0, nil
	}
	beforeLaunchStateWrite(plan.accountPath)
	if !sameContent(plan.accountPath, plan.before, plan.data) {
		return LaunchStateRefused, 0, errors.New(filepath.Base(plan.accountPath) + " changed while Relay read it; it was not changed")
	}
	if plan.before.exists {
		supported, swapErr := replaceVerified(plan.accountPath, plan.data, plan.next)
		if !supported {
			// Never a plain rename: no check (idle, content) keeps an agent
			// from saving between it and the rename.
			return LaunchStateSkipped, 0, errors.New(errNoAtomicExchange.Error() + "; " + filepath.Base(plan.accountPath) +
				" was not changed, so the main account's first-run and trust answers were not copied into it")
		}
		err = swapErr
	} else {
		err = writeNew(plan.accountPath, plan.next)
	}
	if err != nil {
		return LaunchStateRefused, 0, err
	}
	return LaunchStateUpdated, plan.added, nil
}

// replaceVerified puts next at path only if the file it displaces is byte
// for byte data. next is written to a temporary file beside path and the two
// are exchanged in one step (renamex_np RENAME_SWAP, renameat2
// RENAME_EXCHANGE); the temporary path then holds the displaced file. If that
// is not data, a provider saved in between: its save is exchanged back, and
// again while saves keep landing, so on every return the newest save is at
// path. supported is false, with nothing changed, when the file system has no
// atomic exchange.
func replaceVerified(path string, data, next []byte) (supported bool, err error) {
	return replaceChecked(path, next, func(displaced string) bool { return holds(displaced, data) })
}

// replaceChecked is replaceVerified for any expected displaced entry: was
// reports whether the entry the exchange moved out of path is the one Relay
// read (a file with the same bytes, or the same link).
func replaceChecked(path string, next []byte, was func(displaced string) bool) (supported bool, err error) {
	return replaceCheckedMode(path, next, 0o600, was)
}

// replaceCheckedMode is replaceChecked writing next with mode.
func replaceCheckedMode(path string, next []byte, mode os.FileMode, was func(displaced string) bool) (supported bool, err error) {
	temp, err := writeTemp(path, next, mode)
	if err != nil {
		return true, err
	}
	keep := false
	defer func() {
		if !keep {
			os.Remove(temp)
		}
	}()
	if supported, err := launchStateExchange(temp, path); err != nil {
		return supported, err
	}
	afterLaunchStateSwap(path)
	if was(temp) {
		if !holds(path, next) {
			// A save replaced the merged copy after the exchange; it is kept.
			return true, errConcurrentSave
		}
		return true, nil
	}
	// placed is what the last exchange put at path; the temporary path must
	// come back holding exactly it, or a newer save landed there meanwhile.
	placed := next
	for swap := 0; swap < launchStateSwaps; swap++ {
		displaced, readErr := readBounded(temp, 16<<20)
		if readErr != nil {
			keep = true
			return true, errors.New("a concurrent save could not be verified; it is kept at " + temp)
		}
		if _, err := launchStateExchange(temp, path); err != nil {
			keep = true
			return true, errors.New("a concurrent save could not be restored; it is kept at " + temp + ": " + err.Error())
		}
		if holds(temp, placed) {
			return true, errConcurrentSave
		}
		placed = displaced
	}
	keep = true
	return true, errors.New("the account file kept changing while Relay restored it; the last displaced copy is kept at " + temp)
}

// isLinkTo reports whether path is a symbolic link to exactly target.
func isLinkTo(path, target string) bool {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return false
	}
	link, err := os.Readlink(path)
	return err == nil && link == target
}

// holds reports whether path is a regular file with exactly data.
func holds(path string, data []byte) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	now, err := readBounded(path, 16<<20)
	return err == nil && bytes.Equal(now, data)
}

// readAccountFile reads an account's own configuration file: absent, or a
// regular file owned by this user.
func readAccountFile(path string, limit int64) (fileState, []byte, error) {
	before := observe(path)
	switch {
	case before.failed:
		return before, nil, errors.New(filepath.Base(path) + " could not be read; it was not changed")
	case !before.exists:
		return before, nil, nil
	case !before.info.Mode().IsRegular() || !ownedByUser(before.info):
		return before, nil, errors.New(filepath.Base(path) + " is a link or not owned by this user; it was not changed")
	}
	data, err := readBounded(path, limit)
	return before, data, err
}

func planClaudeLaunchState(mainPath, accountPath string) (launchStatePlan, error) {
	plan := launchStatePlan{accountPath: accountPath}
	wanted := map[string]bool{"projects": true}
	for _, key := range claudeFirstRunKeys {
		wanted[key] = true
	}
	main, err := readJSONKeys(mainPath, wanted)
	if err != nil {
		return plan, errors.New("the main .claude.json could not be read: " + err.Error())
	}
	if len(main) == 0 {
		return plan, nil
	}
	if plan.before, plan.data, err = readAccountFile(accountPath, 16<<20); err != nil {
		return plan, err
	}
	document := map[string]json.RawMessage{}
	if plan.before.exists && (json.Unmarshal(plan.data, &document) != nil || document == nil) {
		return plan, errors.New("the account's .claude.json is not a JSON object; it was not changed")
	}
	for _, key := range claudeFirstRunKeys {
		if value, ok := main[key]; ok {
			if _, has := document[key]; !has {
				document[key] = value
				plan.added++
			}
		}
	}
	if raw, ok := main["projects"]; ok {
		projects, added, err := mergeProjectTrust(raw, document["projects"])
		if err != nil {
			return plan, err
		}
		if added > 0 {
			document["projects"] = projects
			plan.added += added
		}
	}
	if plan.added == 0 {
		return plan, nil
	}
	plan.next, err = json.MarshalIndent(document, "", "  ")
	return plan, err
}

// mergeProjectTrust adds the main projects' trust answers to the account's
// projects, path by path as the main file spells them. Nothing else of a main
// project entry (its history, sessions or costs) is copied.
func mergeProjectTrust(mainRaw, accountRaw json.RawMessage) (json.RawMessage, int, error) {
	var mainProjects map[string]json.RawMessage
	if json.Unmarshal(mainRaw, &mainProjects) != nil || mainProjects == nil {
		return nil, 0, errors.New("the main .claude.json projects value is not an object")
	}
	projects := map[string]json.RawMessage{}
	if accountRaw != nil && (json.Unmarshal(accountRaw, &projects) != nil || projects == nil) {
		return nil, 0, errors.New("the account's .claude.json projects value is not an object; it was not changed")
	}
	added := 0
	for path, raw := range mainProjects {
		var source map[string]json.RawMessage
		if json.Unmarshal(raw, &source) != nil {
			continue
		}
		entry := map[string]json.RawMessage{}
		if existing, ok := projects[path]; ok && (json.Unmarshal(existing, &entry) != nil || entry == nil) {
			// Not an object: the account's own value is left as it is.
			continue
		}
		changed := false
		for _, key := range claudeProjectTrustKeys {
			if value, ok := source[key]; ok {
				if _, has := entry[key]; !has {
					entry[key] = value
					changed = true
					added++
				}
			}
		}
		if changed {
			data, err := json.Marshal(entry)
			if err != nil {
				return nil, 0, err
			}
			projects[path] = data
		}
	}
	data, err := json.Marshal(projects)
	return data, added, err
}

// planCodexTrust appends the main config.toml's [projects."<path>"]
// trust_level answers that the account's own config.toml has no table for.
// An account file linked to the main file already shares them. The account's
// text is kept as it is; the result must parse and hold each copied answer.
func planCodexTrust(mainPath, accountPath string) (launchStatePlan, error) {
	plan := launchStatePlan{accountPath: accountPath}
	main, _, _, err := readCodexMain(mainPath)
	if err != nil {
		return plan, errors.New("the main Codex config.toml could not be read: " + err.Error())
	}
	if main == nil {
		return plan, nil
	}
	mainProjects := main.root.table("projects")
	if mainProjects == nil {
		return plan, nil
	}
	plan.before = observe(accountPath)
	if plan.before.exists && plan.before.info.Mode()&os.ModeSymlink != 0 && plan.before.link == mainPath {
		return launchStatePlan{accountPath: accountPath, before: plan.before}, nil
	}
	if plan.before, plan.data, err = readAccountFile(accountPath, 4<<20); err != nil {
		return plan, err
	}
	own, err := parseTOML(string(plan.data))
	if err != nil {
		return plan, errors.New("the account's own " + err.Error() + "; it was not changed")
	}
	ownProjects := own.root.table("projects")
	var appended strings.Builder
	copied := map[string]any{}
	for _, path := range mainProjects.keys {
		project := mainProjects.table(path)
		if project == nil {
			continue
		}
		value, ok := project.values[codexTrustKey]
		if _, isString := value.(string); !ok || !isString {
			continue
		}
		if ownProjects != nil {
			if _, has := ownProjects.values[path]; has {
				continue
			}
		}
		table := newTOMLTable()
		table.set(codexTrustKey, value)
		tomlEmitTable(&appended, []string{"projects", path}, table)
		copied[path] = value
	}
	if len(copied) == 0 {
		return plan, nil
	}
	text := codexWithTrust(string(plan.data), appended.String())
	written, err := parseTOML(text)
	if err != nil {
		return plan, errors.New("the account's config.toml defines its projects in a way Relay will not extend; it was not changed")
	}
	for path, value := range copied {
		project := written.root.table("projects").table(path)
		if project == nil || project.values[codexTrustKey] != value {
			return plan, errors.New("the account's config.toml could not be verified after adding project trust; it was not changed")
		}
	}
	plan.next, plan.added = []byte(text), len(copied)
	return plan, nil
}

// codexWithTrust adds the project tables at the end of the account's own
// settings: before the MCP tables Relay copied, where a later sync keeps
// them, so the two merges never reorder each other's text.
func codexWithTrust(text, tables string) string {
	tables = strings.TrimRight(tables, "\n")
	if index := strings.Index(text, codexMergeMarker+"\n"); index >= 0 && (index == 0 || text[index-1] == '\n') {
		own := strings.TrimRight(text[:index], "\n")
		if own != "" {
			own += "\n\n"
		}
		return own + tables + "\n\n" + text[index:]
	}
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	if text != "" {
		text += "\n"
	}
	return text + tables + "\n"
}

// writeNew creates path with data only if nothing is there yet.
func writeNew(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".relay-account-*")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Link(name, path)
}

// PrepareLaunch runs before an agent starts with the account folder value
// (the provider's config directory variable): it adds the main account's
// first-run and trust answers to that account. It never blocks a launch: what
// it could not do is returned as a note. It does nothing for the main
// account or while an accounts request holds the accounts lock. It runs while
// other agents use the account (the user's choice): the merge only adds, and
// its write is checked byte for byte, so a live agent's save made before the
// check is kept. A save in the instant after it can replace the merge, which
// the next launch makes again.
func PrepareLaunch(home, provider, value string) string {
	if value == "" || !filepath.IsAbs(value) {
		return ""
	}
	resolved := resolvedRoot(value)
	if resolved == resolvedRoot(defaultRoot(home, provider)) {
		return ""
	}
	registry, err := Load(home)
	if err != nil {
		return "the account list could not be read, so first-run settings were not copied into this account"
	}
	var account *Account
	for index := range registry.Accounts {
		candidate := registry.Accounts[index]
		if candidate.Provider == provider && candidate.Dir != "" && resolvedRoot(candidate.Root(home)) == resolved {
			account = &candidate
			break
		}
	}
	if account == nil {
		return ""
	}
	unlock, err := lockAccounts(home, false)
	if err != nil {
		return "an accounts change is in progress, so first-run settings were not copied into this account"
	}
	defer unlock()
	if _, _, err := mergeLaunchState(home, *account); err != nil {
		return "first-run settings were not copied into this account: " + err.Error()
	}
	return ""
}
