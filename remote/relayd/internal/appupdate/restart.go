package appupdate

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

func (e *Engine) Quit(app string, timeout time.Duration) error {
	pids, err := e.AppPIDs(app)
	if err != nil {
		return err
	}
	if len(pids) == 0 {
		return nil
	}
	queue, err := e.Watch()
	if err != nil {
		return err
	}
	defer queue.Close()
	for _, pid := range pids {
		if err = queue.Register(pid); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return err
		}
	}
	seconds := int(timeout / time.Second)
	if _, err = e.command(timeout+2*time.Second, "/usr/bin/osascript", "-e", fmt.Sprintf("with timeout of %d seconds", seconds), "-e", `tell application id "dev.relay.terminal" to quit`, "-e", "end timeout"); err != nil {
		return err
	}
	deadline := e.Now().Add(timeout)
	current, err := e.AppPIDs(app)
	if err != nil {
		return err
	}
	remaining := map[int]bool{}
	for _, pid := range pids {
		for _, now := range current {
			if pid == now {
				remaining[pid] = true
			}
		}
	}
	for len(remaining) > 0 {
		duration := deadline.Sub(e.Now())
		if duration <= 0 {
			return errors.New("Relay did not quit; installation was not performed")
		}
		events, err := queue.Wait(len(pids), duration)
		if err != nil {
			return err
		}
		if len(events) == 0 {
			return errors.New("Relay did not quit; installation was not performed")
		}
		for _, pid := range events {
			delete(remaining, pid)
		}
	}
	current, err = e.AppPIDs(app)
	if err != nil {
		return err
	}
	if len(current) > 0 {
		return errors.New("another Relay instance appeared; installation was not performed")
	}
	return nil
}

type RestartOptions struct {
	App, Candidate, Preservation, Trace string
	Timeout                             int
}

func (e *Engine) Restart(o RestartOptions) (map[string]any, error) {
	if o.Timeout < 1 || o.Timeout > 60 {
		return nil, errors.New("timeout must be between 1 and 60 seconds")
	}
	if o.Candidate != "" && o.Preservation != "" {
		return nil, errors.New("candidate and preservation root are exclusive")
	}
	if o.App == "" {
		o.App = e.Config.Installed
	}
	app, err := absolute(o.App)
	if err != nil {
		return nil, err
	}
	var preservation, candidate string
	if o.Preservation != "" {
		canonical, err := absolute(e.Config.Installed)
		if err != nil {
			return nil, err
		}
		if app != canonical {
			return nil, errors.New("preservation requires the installed app path")
		}
		preservation, err = e.receiptRoot(o.Preservation)
		if err != nil {
			return nil, err
		}
		if _, err = e.baseline(preservation); err != nil {
			return nil, err
		}
	}
	trace := ""
	if o.Trace != "" {
		trace, err = filepath.Abs(o.Trace)
		if err != nil {
			return nil, err
		}
		if preservation == "" || filepath.Dir(trace) != preservation || filepath.Base(trace) != "terminal-replay-trace.log" {
			return nil, errors.New("replay trace must be inside private preservation receipt")
		}
		if _, err = os.Lstat(trace); err == nil || !os.IsNotExist(err) {
			return nil, errors.New("replay trace must be a new file")
		}
	}
	if o.Candidate != "" {
		candidate, err = absolute(o.Candidate)
		if err != nil {
			return nil, err
		}
		if candidate == app {
			return nil, errors.New("candidate must be a separate bundle")
		}
	}
	target := app
	if candidate != "" {
		target = candidate
	}
	if preservation != "" {
		target = filepath.Join(preservation, "Relay.app")
	}
	expected, err := e.verifyBundle(target)
	if err != nil {
		return nil, err
	}
	previous, err := e.verifyBundle(app)
	if err != nil {
		return nil, err
	}
	lock, err := lockFile(e.globalLock(), e.Config.UID)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if trace != "" {
		if err = writePrivate(trace, nil); err != nil {
			return nil, err
		}
	}
	if err = e.Quit(app, time.Duration(o.Timeout)*time.Second); err != nil {
		return nil, err
	}
	result := map[string]any{"launched": app, "expectedExecutableSHA256": expected}
	if preservation != "" {
		_, err = e.apply(preservation, true)
		if err == nil {
			var actual string
			actual, err = e.verifyBundle(app)
			if err == nil && actual != expected {
				err = errors.New("installed executable differs from staged candidate")
			}
		}
		if err != nil {
			if actual, x := e.verifyBundle(app); x == nil && actual == previous {
				if _, x = e.command(30*time.Second, "/usr/bin/open", "-a", app); x != nil {
					return nil, fmt.Errorf("%w; previous UI reopen failed: %v", err, x)
				}
			}
			return nil, err
		}
		result["preservationReceipt"] = preservation
	} else if candidate != "" {
		now, err := e.verifyBundle(candidate)
		if err != nil {
			return nil, err
		}
		if now != expected {
			return nil, errors.New("candidate changed during quit")
		}
		installed, err := e.verifyBundle(app)
		if err != nil {
			return nil, err
		}
		if installed != previous {
			return nil, errors.New("installed app changed during quit")
		}
		backup := filepath.Join(e.Config.TempRoot, "relay-before-restart-"+e.Now().Format("20060102-150405")+".app")
		if _, x := os.Lstat(backup); x == nil || !os.IsNotExist(x) {
			return nil, errors.New("backup already exists")
		}
		if err = os.Rename(app, backup); err != nil {
			return nil, err
		}
		rollback := func(cause error) error {
			if _, x := os.Lstat(app); x == nil {
				if x = os.Rename(app, candidate); x != nil {
					return fmt.Errorf("%w; candidate restore failed: %v", cause, x)
				}
			}
			if x := os.Rename(backup, app); x != nil {
				return fmt.Errorf("%w; app rollback failed: %v", cause, x)
			}
			return cause
		}
		if err = os.Rename(candidate, app); err != nil {
			return nil, rollback(err)
		}
		actual, err := e.verifyBundle(app)
		if err != nil {
			return nil, rollback(err)
		}
		if actual != expected {
			return nil, rollback(errors.New("installed executable differs from candidate"))
		}
		result["backup"] = backup
	}
	launch := []string{"/usr/bin/open", "-a", app}
	if trace != "" {
		launch = append(launch, "--env", "RELAY_REPLAY_TRACE=1", "--stderr", trace)
	}
	if _, err = e.command(30*time.Second, launch...); err != nil {
		return nil, err
	}
	return result, nil
}

func (e *Engine) globalLock() string {
	return filepath.Join(e.Config.LockRoot, "relay-restart-"+strconv.Itoa(e.Config.UID)+".lock")
}
