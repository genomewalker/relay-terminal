package agentaccounts

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Removed reports where a removed account's folder now is ("" when it had
// no folder).
type Removed struct {
	Provider string `json:"provider"`
	Label    string `json:"label"`
	MovedTo  string `json:"moved_to,omitempty"`
	// KeptAt is the private name the folder was left under when it could
	// not be retired or put back.
	KeptAt string `json:"kept_at,omitempty"`
	// Recreated is the old path when something created it again during the
	// removal; it is not registered.
	Recreated string `json:"recreated,omitempty"`
}

// logoutRunner signs one account out with its provider's own command; tests
// replace it.
var logoutRunner = ProviderLogout

// removeProbe checks the login state after a refused sign-out; tests
// replace it.
var removeProbe Prober = ProviderProbe

// ProviderLogout runs `claude auth logout` or `codex logout` with only the
// account variable changed. The provider removes its own credentials; Relay
// never reads or deletes them.
func ProviderLogout(ctx context.Context, provider, override string) error {
	name, args, variable := "claude", []string{"auth", "logout"}, "CLAUDE_CONFIG_DIR"
	if provider == "codex" {
		name, args, variable = "codex", []string{"logout"}, "CODEX_HOME"
	} else if provider != "claude" {
		return errors.New("unsupported provider")
	}
	executable, err := ProviderExecutable(name)
	if err != nil {
		return err
	}
	command := exec.CommandContext(ctx, executable, args...)
	defer isolate(command)()
	command.WaitDelay = waitLimit
	command.Dir = os.TempDir()
	command.Env = accountEnvironment(variable, override)
	// What the provider prints is discarded: it can contain credential
	// material.
	started := time.Now()
	if err := command.Run(); err != nil || ctx.Err() != nil {
		return failure(ctx, name, started, err)
	}
	return nil
}

// Remove signs an account out, moves its folder to
// ~/.local/share/relay/retired-accounts-<date>/ and forgets the slot. It is
// refused for the default directory, for a folder that is a link or shares
// a directory with another account, and while an agent uses the account. The
// folder is renamed as a whole: links inside it move as links, and nothing
// they point to is touched.
//
// The slot is forgotten first, so Relay starts no new agent with it (see
// AdmitLaunch). The folder is then renamed to a private name beside it and
// checked for users by its real path; the provider signs out there, and only
// then is it moved to the retired folder. A refusal after the rename puts the
// folder back and restores the slot, unless something recreated the old path
// meanwhile: that path is never replaced, and the original stays at its
// private name, reported and unregistered. Each step is journaled so an
// interrupted removal is finished or undone (RecoverRemovals): at every
// point the slot is either registered with its folder at its path, or
// forgotten with the folder set aside or retired.
//
// Origin is a declaration under the host transport's trust boundary, not
// proof of who asked; launches outside Relay that use the folder only through
// its old path after the rename are not seen, and the old path is then
// reported as recreated.
func Remove(home string, registry Registry, provider, label string, now time.Time) (Registry, Removed, error) {
	account, ok := registry.Find(provider, label)
	if !ok {
		return Registry{}, Removed{}, errors.New("unknown account")
	}
	if account.Dir == "" {
		return Registry{}, Removed{}, errors.New("the account on " + provider + "'s default folder cannot be removed; sign it out instead")
	}
	root := account.Root(home)
	removed := Removed{Provider: provider, Label: label}
	info, err := os.Lstat(root)
	exists := err == nil
	switch {
	case err != nil && !errors.Is(err, os.ErrNotExist):
		return Registry{}, Removed{}, errors.New("the account folder cannot be checked; nothing was changed")
	case exists && info.Mode()&os.ModeSymlink != 0:
		return Registry{}, Removed{}, errors.New("the account folder is a link; Relay never moves what a link points to. Nothing was changed.")
	case exists && !info.IsDir():
		return Registry{}, Removed{}, errors.New("the account path is not a folder; nothing was changed")
	}
	resolved := resolvedRoot(root)
	index := -1
	for position, other := range registry.Accounts {
		if other.Provider == provider && other.Label == label {
			index = position
			continue
		}
		otherRoot := resolvedRoot(other.Root(home))
		if otherRoot == resolved || within(otherRoot, resolved) || within(resolved, otherRoot) {
			return Registry{}, Removed{}, errors.New("another account uses this folder; nothing was changed")
		}
	}
	for _, main := range []string{defaultRoot(home, "claude"), defaultRoot(home, "codex")} {
		if err := distinctRoots(main, root); err != nil {
			return Registry{}, Removed{}, err
		}
	}
	kept := Registry{Version: registryVersion}
	for _, other := range registry.Accounts {
		if other.Provider != provider || other.Label != label {
			kept.Accounts = append(kept.Accounts, other)
		}
	}
	random := make([]byte, 8)
	if _, err := rand.Read(random); err != nil {
		return Registry{}, Removed{}, err
	}
	id := hex.EncodeToString(random)
	if !exists {
		return removeSlot(home, kept, removal{ID: id, Account: account, Index: index, Root: root, Missing: true})
	}
	if pids, err := inUse(provider, root); err != nil {
		return Registry{}, Removed{}, errors.New("could not verify that no agent is using this account; nothing was changed")
	} else if pids != "" {
		return Registry{}, Removed{}, errors.New("Stop the " + provider + " agents using this account first (pids " +
			pids + "); nothing was changed.")
	}
	retired, err := retiredDirectory(home, now)
	if err != nil {
		return Registry{}, Removed{}, err
	}
	if !sameDevice(filepath.Dir(root), retired) {
		return Registry{}, Removed{}, errors.New("the account folder is on another filesystem than " + retired +
			"; Relay only moves it in one step. Nothing was changed.")
	}
	job := removal{ID: id, Account: account, Index: index, Root: root,
		Staged:      filepath.Join(filepath.Dir(root), "."+strings.TrimPrefix(filepath.Base(root), ".")+".removing-"+id),
		Destination: filepath.Join(retired, provider+"-"+label+"-"+now.Format("150405")+"-"+id[:6])}
	dev, inode, ok := folderIdentity(root)
	if !ok {
		return Registry{}, Removed{}, errors.New("the account folder cannot be identified; nothing was changed")
	}
	job.Dev, job.Inode = dev, inode
	if present(job.Staged) || present(job.Destination) {
		return Registry{}, Removed{}, errors.New("the folder name for the removal is taken; nothing was changed")
	}
	if err := writeRemoval(home, job); err != nil {
		return Registry{}, Removed{}, errors.New("the removal could not be recorded; nothing was changed")
	}
	if removeCrash("recorded") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	// 1. Forget the slot: from here Relay starts no agent with this folder.
	saved, err := Save(home, kept)
	if err != nil {
		_ = dropRemoval(home, job)
		return Registry{}, Removed{}, errors.New("the slot could not be forgotten; nothing was changed")
	}
	if removeCrash("unregistered") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	// 2. Fence the folder under a private name, then look for anything
	// still using it.
	if err := moveFolder(home, &job, root, job.Staged); err != nil {
		if errors.Is(err, errRemovalCrashed) {
			return Registry{}, Removed{}, err
		}
		if _, err := reregister(home, job); err != nil {
			return Registry{}, Removed{}, errors.New("the folder could not be set aside and the slot could not be restored yet; " +
				"the next accounts request restores it")
		}
		_ = dropRemoval(home, job)
		return Registry{}, Removed{}, errors.New("the account folder could not be set aside, so nothing was signed out, moved or removed: " +
			shortReason(err))
	}
	job.Moved = true
	_ = writeRemoval(home, job)
	if removeCrash("staged") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	if pids, err := liveUsers(provider, root, job.Staged); err != nil {
		return putBack(home, job, "Relay could not verify that nothing uses this account, so it was not signed out")
	} else if pids != "" {
		return putBack(home, job, "Stop the processes using this account first (pids "+pids+"); it was not signed out")
	}
	if removeCrash("checked") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	// 3. Sign out in the fenced folder.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	err = logoutRunner(ctx, provider, job.Staged)
	cancel()
	if err != nil {
		// A provider may refuse to sign out an account that is not
		// signed in; its own status command decides.
		fenced := Account{Provider: provider, Label: label, Dir: job.Staged}
		if status := AccountStatus(home, fenced, removeProbe); status.Probe != "ok" || status.LoggedIn != "no" {
			return putBack(home, job, "sign-out failed, so nothing was moved or removed: "+shortReason(err))
		}
	}
	job.Step = removalSignedOut
	_ = writeRemoval(home, job)
	if removeCrash("signed_out") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	if pids, err := liveUsers(provider, root, job.Staged); err != nil || pids != "" {
		reason := "signed out, but Relay could not verify that nothing started using this account meanwhile"
		if pids != "" {
			reason = "signed out, but processes started using this account meanwhile (pids " + pids + ")"
		}
		return putBack(home, job, reason)
	}
	// 4. Retire the folder.
	if err := moveFolder(home, &job, job.Staged, job.Destination); err != nil {
		if errors.Is(err, errRemovalCrashed) {
			return Registry{}, Removed{}, err
		}
		removed.KeptAt = job.Staged
		return saved, removed, errors.New("signed out and set aside at " + job.Staged + ", but it could not be moved to " + retired +
			"; the slot was removed and the next accounts request moves it: " + shortReason(err))
	}
	if removeCrash("retired") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	_ = dropRemoval(home, job)
	removed.MovedTo = job.Destination
	if present(root) {
		removed.Recreated = root
	}
	return saved, removed, nil
}

// removeSlot forgets the slot of an account that has no folder. A missing
// folder is no proof that nothing uses the account: a launch admitted before
// the slot is forgotten names it in its environment. The slot is forgotten
// first, so no later launch is admitted, then this user's processes are
// scanned; any user, or a failed scan, restores the slot.
func removeSlot(home string, kept Registry, job removal) (Registry, Removed, error) {
	removed := Removed{Provider: job.Account.Provider, Label: job.Account.Label}
	if err := writeRemoval(home, job); err != nil {
		return Registry{}, Removed{}, errors.New("the removal could not be recorded; nothing was changed")
	}
	if removeCrash("recorded") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	saved, err := Save(home, kept)
	if err != nil {
		_ = dropRemoval(home, job)
		return Registry{}, Removed{}, errors.New("the slot could not be forgotten; nothing was changed")
	}
	if removeCrash("unregistered") {
		return Registry{}, Removed{}, errRemovalCrashed
	}
	if pids, err := liveUsers(job.Account.Provider, job.Root); err != nil || pids != "" {
		reason := "Relay could not verify that nothing uses this account"
		if pids != "" {
			reason = "Stop the processes using this account first (pids " + pids + ")"
		}
		if _, err := reregister(home, job); err != nil {
			return Registry{}, Removed{}, errors.New(reason + "; its slot will be restored by the next accounts request")
		}
		_ = dropRemoval(home, job)
		return Registry{}, Removed{}, errors.New(reason + "; nothing was changed")
	}
	_ = dropRemoval(home, job)
	return saved, removed, nil
}

// retiredDirectory is today's owner-only folder for removed accounts.
func retiredDirectory(home string, now time.Time) (string, error) {
	path := filepath.Join(home, ".local", "share", "relay", "retired-accounts-"+now.Format("20060102"))
	if err := os.MkdirAll(path, 0o700); err != nil {
		return "", errors.New("the retired accounts folder cannot be created; nothing was changed")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", errors.New("the retired accounts folder cannot be checked; nothing was changed")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || int(stat.Uid) != os.Getuid() {
		return "", errors.New("the retired accounts folder is not this user's own folder; nothing was changed")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return "", err
	}
	return path, nil
}

// Rename changes a slot's label only: its folder and login stay as they are.
func Rename(home string, registry Registry, provider, label, newLabel string) (Registry, error) {
	if _, ok := registry.Find(provider, label); !ok {
		return Registry{}, errors.New("unknown account")
	}
	if !labelPattern.MatchString(newLabel) {
		return Registry{}, errors.New("account labels use 1-24 lowercase letters, digits, '-' or '_'")
	}
	if _, taken := registry.Find(provider, newLabel); taken {
		return Registry{}, errors.New(provider + " already has an account named " + newLabel)
	}
	changed := Registry{Version: registryVersion}
	for _, account := range registry.Accounts {
		if account.Provider == provider && account.Label == label {
			account.Label = newLabel
		}
		changed.Accounts = append(changed.Accounts, account)
	}
	return Save(home, changed)
}

// SetExpectation records the workspace and plan a slot is meant for.
func SetExpectation(home string, registry Registry, provider, label, workspace, plan, key string) (Registry, error) {
	if _, ok := registry.Find(provider, label); !ok {
		return Registry{}, errors.New("unknown account")
	}
	changed := Registry{Version: registryVersion}
	for _, account := range registry.Accounts {
		if account.Provider == provider && account.Label == label {
			account.ExpectWorkspace, account.ExpectPlan, account.ExpectKey = workspace, plan, key
		}
		changed.Accounts = append(changed.Accounts, account)
	}
	return Save(home, changed)
}

// KeepExpectations carries each slot's expectation over a configure from a
// client that does not send expectations.
func KeepExpectations(current, incoming Registry) Registry {
	for index, account := range incoming.Accounts {
		if account.ExpectWorkspace != "" || account.ExpectPlan != "" || account.ExpectKey != "" {
			continue
		}
		if previous, ok := current.Find(account.Provider, account.Label); ok {
			incoming.Accounts[index].ExpectWorkspace = previous.ExpectWorkspace
			incoming.Accounts[index].ExpectPlan = previous.ExpectPlan
			incoming.Accounts[index].ExpectKey = previous.ExpectKey
		}
	}
	return incoming
}

// inUse checks which agents use an account; tests replace it.
var inUse = agentsUsing

// agentsUsing lists the pids of agents whose account variable selects any of
// the given roots ("" when there are none).
func agentsUsing(provider string, roots ...string) (string, error) {
	seen := map[int]bool{}
	var pids []string
	for _, root := range roots {
		running, err := runningAgents(provider, root)
		if err != nil {
			return "", err
		}
		for _, process := range running {
			if !seen[process.pid] {
				seen[process.pid] = true
				pids = append(pids, strconv.Itoa(process.pid))
			}
		}
	}
	return strings.Join(pids, ", "), nil
}
