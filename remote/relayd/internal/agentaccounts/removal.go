package agentaccounts

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

// A removal is fenced, not just checked. Remove first forgets the slot, so
// no new Relay launch accepts the folder (AdmitLaunch), then renames the
// folder to a private name beside it and looks for anything still using it.
// The journal below records each removal until it ends, so an interrupted
// one is finished or undone by RecoverRemovals:
//   - before the folder is set aside: the slot is restored;
//   - set aside, not signed out: the folder is put back and the slot restored;
//   - signed out: the folder is moved to the retired accounts folder.
//
// A folder that something recreated at the old path is never replaced,
// deleted or registered: the original stays at its private name, the slot
// stays forgotten, and the journal keeps saying where it is.
type removal struct {
	ID          string  `json:"id"`
	Account     Account `json:"account"`
	Index       int     `json:"index"`
	Root        string  `json:"root"`
	Staged      string  `json:"staged"`
	Destination string  `json:"destination"`
	// Step is "" until the provider signed the account out, then
	// "signed_out"; "kept" when the old path was recreated meanwhile.
	Step string `json:"step,omitempty"`
	// Missing: the account had no folder; only its slot is removed.
	Missing bool `json:"missing,omitempty"`
	// Dev and Inode identify the account folder, recorded before it moves
	// (a rename keeps them; zero in records written before v1e). Moved is
	// set once the folder was renamed to Staged.
	Dev   uint64 `json:"dev,omitempty"`
	Inode uint64 `json:"inode,omitempty"`
	Moved bool   `json:"moved,omitempty"`
	// Reserved is the empty folder the fallback rename created as the
	// target of its next rename, with its identity, so recovery can tell
	// that placeholder from the account folder.
	Reserved *reservation `json:"reserved,omitempty"`
}

type reservation struct {
	Path  string `json:"path"`
	Dev   uint64 `json:"dev"`
	Inode uint64 `json:"inode"`
}

const (
	removalSignedOut = "signed_out"
	removalKept      = "kept"
)

var removalID = regexp.MustCompile(`^[0-9a-f]{16}$`)

// removeCrash stops Remove at a named step as if relayd had died there;
// tests replace it.
var removeCrash = func(step string) bool { return false }

var errRemovalCrashed = errors.New("removal stopped (test crash point)")

func removalsDir(home string) string { return filepath.Join(home, ".relay", "agent-account-removals") }

func writeRemoval(home string, job removal) error {
	dir := removalsDir(home)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(job, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(dir, job.ID+".json"), append(data, '\n'), 0o600)
}

func dropRemoval(home string, job removal) error {
	err := os.Remove(filepath.Join(removalsDir(home), job.ID+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// pendingRemovals reads every journal entry; one that cannot be read is
// left on disk and reported.
func pendingRemovals(home string) ([]removal, []string) {
	entries, err := os.ReadDir(removalsDir(home))
	if err != nil {
		return nil, nil
	}
	var jobs []removal
	var notes []string
	for _, entry := range entries {
		name := entry.Name()
		id, ok := strings.CutSuffix(name, ".json")
		if !ok || !removalID.MatchString(id) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(removalsDir(home), name))
		var job removal
		if err != nil || len(data) > 65536 || json.Unmarshal(data, &job) != nil || job.ID != id || !filepath.IsAbs(job.Root) ||
			(!job.Missing && (filepath.Dir(job.Staged) != filepath.Dir(job.Root) || !filepath.IsAbs(job.Destination))) {
			notes = append(notes, "an interrupted account removal record ("+name+") cannot be read; it was left in "+removalsDir(home))
			continue
		}
		jobs = append(jobs, job)
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].ID < jobs[j].ID })
	return jobs, notes
}

// RecoverRemovals finishes or undoes removals that relayd did not complete.
// It runs under the accounts lock, before any other account change. The
// returned notes say what was done and what needs the user.
func RecoverRemovals(home string) []string {
	jobs, notes := pendingRemovals(home)
	for _, job := range jobs {
		name := job.Account.Provider + " account " + job.Account.Label
		if job.Missing {
			// Stopped before its scan finished: the slot is restored.
			if _, err := reregister(home, job); err != nil {
				notes = append(notes, "the slot of the "+name+" could not be restored yet")
				continue
			}
			_ = dropRemoval(home, job)
			notes = append(notes, "an interrupted removal of the "+name+" was undone")
			continue
		}
		job = clearReservations(home, job)
		root, staged, destination := present(job.Root), present(job.Staged), present(job.Destination)
		if job.Inode == 0 && countTrue(root, staged, destination) > 1 {
			// A record from before v1e carries no identity, so it cannot
			// show which folder is the account. Nothing is changed.
			notes = append(notes, holdNote(name, job, "this removal was recorded by an older Relay without the folder's identity"))
			continue
		}
		if job.Inode != 0 {
			// Where the account folder is, by the identity recorded before it
			// moved; a path that exists but is not that folder is never taken
			// for it.
			original := ""
			for _, path := range []string{job.Root, job.Staged, job.Destination} {
				if job.isOriginal(path) {
					original = path
				}
			}
			root, staged, destination = original == job.Root, original == job.Staged, original == job.Destination
			if original == "" {
				notes = append(notes, holdNote(name, job, "the account folder is not at any of its recorded paths"))
				continue
			}
			if staged && present(job.Root) && job.Step != removalSignedOut && job.Step != removalKept {
				job.Step = removalKept
				_ = writeRemoval(home, job)
				notes = append(notes, keptNote(name, job))
				continue
			}
		}
		switch {
		case job.Step == removalKept:
			notes = append(notes, keptNote(name, job))
		case staged && job.Step == removalSignedOut:
			// The same last check as Remove: nothing may use the folder
			// when it is retired. Otherwise it stays set aside, journaled.
			if pids, err := liveUsers(job.Account.Provider, job.Root, job.Staged); err != nil || pids != "" {
				reason := "Relay could not verify that nothing uses it"
				if pids != "" {
					reason = "processes still use it (pids " + pids + ")"
				}
				notes = append(notes, "the "+name+" was signed out and is kept at "+job.Staged+" because "+reason+
					"; the next accounts request tries again to retire it")
				continue
			}
			if err := moveFolder(home, &job, job.Staged, job.Destination); err != nil {
				notes = append(notes, "the "+name+" was signed out and is kept at "+job.Staged+"; it could not be moved to "+
					filepath.Dir(job.Destination)+" yet")
				continue
			}
			_ = dropRemoval(home, job)
			notes = append(notes, "an interrupted removal of the "+name+" was finished: its folder is in "+job.Destination)
			if present(job.Root) {
				notes = append(notes, job.Root+" was recreated during that removal and is not registered")
			}
		case staged && present(job.Root):
			job.Step = removalKept
			_ = writeRemoval(home, job)
			notes = append(notes, keptNote(name, job))
		case staged:
			if err := moveFolder(home, &job, job.Staged, job.Root); err != nil {
				notes = append(notes, "an interrupted removal of the "+name+" could not be undone: its folder is kept at "+job.Staged)
				continue
			}
			if _, err := reregister(home, job); err != nil {
				notes = append(notes, "the folder of the "+name+" is back at "+job.Root+", but its slot could not be restored yet")
				continue
			}
			_ = dropRemoval(home, job)
			notes = append(notes, "an interrupted removal of the "+name+" was undone; nothing was signed out")
		case destination:
			// Archived; the slot was forgotten before the move.
			_ = dropRemoval(home, job)
			if present(job.Root) {
				notes = append(notes, "the "+name+" was removed; "+job.Root+" was recreated afterwards and is not registered")
			}
		case root:
			// Stopped before the folder was set aside, or after it was put
			// back: the folder never left its path. Anything else at the
			// staging name is not the account and is left as it is.
			if _, err := reregister(home, job); err != nil {
				notes = append(notes, "the slot of the "+name+" could not be restored yet")
				continue
			}
			_ = dropRemoval(home, job)
			switch {
			case job.Step == removalSignedOut:
				notes = append(notes, "the "+name+" was signed out, then kept: its folder is at "+job.Root+
					" and its slot was restored; sign it in again to use it")
			case present(job.Staged):
				notes = append(notes, "an interrupted removal of the "+name+" was undone; "+job.Staged+
					" is not the account folder and was left as it is")
			default:
				notes = append(notes, "an interrupted removal of the "+name+" was undone; nothing was signed out")
			}
		default:
			notes = append(notes, holdNote(name, job, "the account folder is not at any of its recorded paths"))
		}
	}
	return notes
}

// holdNote reports a removal recovery leaves untouched because it cannot
// tell which folder is the account.
func holdNote(name string, job removal, why string) string {
	return "an interrupted removal of the " + name + " is on hold: " + why + ". Nothing was changed: " + job.Root + ", " +
		job.Staged + " and " + job.Destination + " (those that exist) were left as they are and the slot stays removed. " +
		"Check them, then delete " + filepath.Join(removalsDir("~"), job.ID+".json") + "."
}

func countTrue(values ...bool) int {
	count := 0
	for _, value := range values {
		if value {
			count++
		}
	}
	return count
}

func keptNote(name string, job removal) string {
	return "the " + name + " is kept at " + job.Staged + ": " + job.Root + " was recreated while it was being removed, " +
		"so Relay left both and did not register either. Move it back yourself once nothing uses " + job.Root + "."
}

// renameNoReplace renames from to to, failing when to exists.
func renameNoReplace(from, to string) error { return renameReserving(from, to, nil) }

// renameChecked is the rename for filesystems without a no-replace rename
// (NFS among them). It first creates to itself with mkdir, which fails when
// anything exists there, so a folder someone else created is never
// replaced; the rename then replaces only that empty placeholder. If the
// rename fails, the placeholder is removed again only while it is empty.
// The system rename is called directly: os.Rename refuses any existing
// folder at to, including the placeholder.
func renameChecked(from, to string) error { return renameFallback(from, to, nil) }

// renameReserving is renameNoReplace that reports the fallback's
// placeholder (path and identity) to reserve before anything is renamed
// onto it; a reserve error removes the placeholder and renames nothing.
func renameReserving(from, to string, reserve func(reservation) error) error {
	if !forceRenameFallback {
		if supported, err := renameExclusive(from, to); supported {
			return err
		}
	}
	return renameFallback(from, to, reserve)
}

// forceRenameFallback makes renameNoReplace use the fallback; tests set it.
var forceRenameFallback = false

func renameFallback(from, to string, reserve func(reservation) error) error {
	if err := os.Mkdir(to, 0o700); err != nil {
		return err
	}
	if reserve != nil {
		dev, inode, ok := folderIdentity(to)
		if !ok {
			_ = os.Remove(to)
			return errors.New("the placeholder folder cannot be identified")
		}
		if err := reserve(reservation{Path: to, Dev: dev, Inode: inode}); err != nil {
			if !errors.Is(err, errRemovalCrashed) {
				_ = os.Remove(to)
			}
			return err
		}
	}
	if err := renameOver(from, to); err != nil {
		_ = os.Remove(to)
		return err
	}
	return nil
}

// moveFolder renames a removal's folder without replacing anything. With
// the fallback, the placeholder is journaled before the folder moves onto
// it, and the journal is cleared again afterwards.
func moveFolder(home string, job *removal, from, to string) error {
	err := renameReserving(from, to, func(placeholder reservation) error {
		job.Reserved = &placeholder
		if err := writeRemoval(home, *job); err != nil {
			job.Reserved = nil
			return err
		}
		if removeCrash("reserved:" + map[string]string{job.Staged: "stage", job.Root: "put_back", job.Destination: "retire"}[to]) {
			return errRemovalCrashed
		}
		return nil
	})
	if errors.Is(err, errRemovalCrashed) {
		return err
	}
	if job.Reserved != nil {
		job.Reserved = nil
		_ = writeRemoval(home, *job)
	}
	return err
}

// isOriginal reports whether path is the account folder itself, by the
// identity recorded before it moved.
func (job removal) isOriginal(path string) bool {
	dev, inode, ok := folderIdentity(path)
	return ok && job.Inode != 0 && dev == job.Dev && inode == job.Inode
}

// clearReservations removes Relay's own empty placeholders that a crash left
// behind, so they are never taken for the account folder: the journaled
// placeholder (matched by identity); the staging name while the recorded
// folder is still at its root; and the archive name while the recorded
// folder is staged. A record without identity clears nothing. Only an
// empty folder that is not the account folder is removed (rmdir).
func clearReservations(home string, job removal) removal {
	clear := func(path string) {
		if !job.isOriginal(path) {
			_ = syscallRmdir(path)
		}
	}
	if job.Reserved != nil {
		if dev, inode, ok := folderIdentity(job.Reserved.Path); ok && dev == job.Reserved.Dev && inode == job.Reserved.Inode {
			clear(job.Reserved.Path)
		}
	}
	// Without a recorded identity nothing here can be told from the
	// account folder, so a record from before v1e clears nothing.
	if job.Inode != 0 && present(job.Staged) && job.isOriginal(job.Root) {
		clear(job.Staged)
	}
	if job.Inode != 0 && job.isOriginal(job.Staged) && present(job.Destination) {
		clear(job.Destination)
	}
	if job.Reserved != nil {
		job.Reserved = nil
		_ = writeRemoval(home, job)
	}
	return job
}

// syscallRmdir is rmdir(2): it removes only an empty folder.
func syscallRmdir(path string) error { return rmdirOnly(path) }

func present(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// reregister puts the removed slot back at its place, exactly as it was.
func reregister(home string, job removal) (Registry, error) {
	current, err := Load(home)
	if err != nil {
		return Registry{}, err
	}
	if _, ok := current.Find(job.Account.Provider, job.Account.Label); ok {
		return current, nil
	}
	index := job.Index
	if index < 0 || index > len(current.Accounts) {
		index = len(current.Accounts)
	}
	restored := Registry{Version: registryVersion}
	restored.Accounts = append(restored.Accounts, current.Accounts[:index]...)
	restored.Accounts = append(restored.Accounts, job.Account)
	restored.Accounts = append(restored.Accounts, current.Accounts[index:]...)
	return Save(home, restored)
}

// putBack ends a refused removal after the folder was set aside: the folder
// returns to its path and the slot is restored. When the old path was
// recreated meanwhile, neither is replaced: the original stays set aside and
// unregistered, and the journal records where.
func putBack(home string, job removal, reason string) (Registry, Removed, error) {
	if err := moveFolder(home, &job, job.Staged, job.Root); err != nil {
		if errors.Is(err, errRemovalCrashed) {
			return Registry{}, Removed{}, err
		}
		job.Step = removalKept
		_ = writeRemoval(home, job)
		return Registry{}, Removed{Provider: job.Account.Provider, Label: job.Account.Label, KeptAt: job.Staged},
			errors.New(reason + "; " + keptNote(job.Account.Provider+" account "+job.Account.Label, job) + " Nothing was deleted.")
	}
	if _, err := reregister(home, job); err != nil {
		return Registry{}, Removed{}, errors.New(reason + "; the folder is back at " + job.Root +
			", and its slot will be restored by the next accounts request")
	}
	_ = dropRemoval(home, job)
	return Registry{}, Removed{}, errors.New(reason + "; its folder and slot are kept")
}

// liveUsers lists processes that still use an account folder set aside for
// removal: agents whose account variable names it (the old path or the set
// aside one), then any of this user's processes with that variable, its
// working directory or an open file there. Relay's launcher keeps the folder
// open across exec (AdmitLaunch), so a Relay launch that was admitted before
// the slot was forgotten is found here.
func liveUsers(provider string, paths ...string) (string, error) {
	if pids, err := inUse(provider, paths...); err != nil || pids != "" {
		return pids, err
	}
	return accountUsers(provider, paths...)
}

// accountUsers is the scan that covers every process of this user. Any
// failure to list processes or open files fails the check.
var accountUsers = scanAccountUsers

func scanAccountUsers(provider string, paths ...string) (string, error) {
	variable, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		return "", err
	}
	wants := make([]string, 0, len(paths))
	for _, path := range paths {
		wants = append(wants, resolvedRoot(path))
	}
	matches := func(path string) bool {
		for _, want := range wants {
			if path == want || within(path, want) {
				return true
			}
		}
		return false
	}
	processes, err := userProcesses()
	if err != nil {
		return "", err
	}
	self := os.Getpid()
	found := map[int]bool{}
	for _, process := range processes {
		if process.pid == self {
			continue
		}
		// A process whose environment cannot be read (it ended, or is a
		// zombie) is still covered by the open-file scan below.
		vars, err := agentlaunch.ProcessEnvironment(process.pid, variable)
		if err == nil && filepath.IsAbs(vars[variable]) && matches(resolvedRoot(vars[variable])) {
			found[process.pid] = true
		}
	}
	open, err := openPaths()
	if err != nil {
		return "", err
	}
	for pid, names := range open {
		if pid == self {
			continue
		}
		for _, name := range names {
			if matches(name) {
				found[pid] = true
				break
			}
		}
	}
	pids := make([]int, 0, len(found))
	for pid := range found {
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	text := make([]string, 0, len(pids))
	for _, pid := range pids {
		text = append(text, strconv.Itoa(pid))
	}
	return strings.Join(text, ", "), nil
}

// LaunchRefusal says why a Relay launch must not start with the account
// folder an agent's variable names (value "" is the provider default, always
// allowed). The folder must be one of this host's registered accounts, so a
// slot that Remove forgot is never started again by Relay. Relay never
// starts an agent on a folder it does not know as an account.
func LaunchRefusal(home, provider, value string) error {
	variable, err := agentlaunch.ConfigDirVariable(provider)
	if err != nil {
		return err
	}
	if value == "" {
		return nil
	}
	if !filepath.IsAbs(value) {
		return errors.New(variable + " must be an absolute path; nothing was started")
	}
	resolved := resolvedRoot(value)
	if resolved == resolvedRoot(defaultRoot(home, provider)) {
		return nil
	}
	registry, err := Load(home)
	if err != nil {
		return errors.New("this host's account list cannot be read, so " + variable + " cannot be checked; nothing was started")
	}
	for _, account := range registry.Accounts {
		if account.Provider == provider && resolvedRoot(account.Root(home)) == resolved {
			return nil
		}
	}
	return errors.New(variable + "=" + value + " is not one of this host's " + provider + " accounts (it may have been removed). " +
		"Add it in Relay's Settings > Accounts, or unset " + variable + ". Nothing was started.")
}

// AdmitLaunch opens the account folder named by value and leaves it open
// across the agent's exec, then checks LaunchRefusal. The open folder is
// what makes this launch visible to a removal that sets the folder aside
// after the check. A folder that cannot be opened refuses the launch, except
// one that does not exist yet (a registered account before its first
// sign-in): that launch is visible to a removal only through the account
// variable in its environment, which the removal scan reads, and Remove
// scans for it before forgetting a slot whose folder is missing.
func AdmitLaunch(home, provider, value string) error {
	if value != "" && filepath.IsAbs(value) {
		if err := holdOpen(value); err != nil && !errors.Is(err, os.ErrNotExist) {
			return errors.New("the account folder " + value + " could not be opened, so it cannot be checked; nothing was started")
		}
	}
	return LaunchRefusal(home, provider, value)
}

// AdmitHeldLaunch is AdmitLaunch for a process whose account variable was
// set after it started (a rotation worker), so the variable is not in its
// visible environment: the folder must exist and be held open.
func AdmitHeldLaunch(home, provider, value string) error {
	if value != "" && filepath.IsAbs(value) {
		if err := holdOpen(value); err != nil {
			return errors.New("the account folder " + value + " could not be opened, so it cannot be checked; nothing was started")
		}
	}
	return LaunchRefusal(home, provider, value)
}
