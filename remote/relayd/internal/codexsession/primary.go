package codexsession

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"syscall"
)

// selectPrimaryThread picks the frontend's own thread among loaded threads that
// share its native TUI origin. Spawned agent threads inherit that origin, so a
// root with an open child reports two matches. Only the threads' own spawn
// records break the tie: exactly one top-level thread, every other match a
// spawned descendant of it. Anything else stays unbound; nothing is inferred
// from process ancestry or ordering.
func selectPrimaryThread(matches []runtimeOrigin, spawnParent func(string) (string, error)) (string, error) {
	unbound := errors.New("native frontend has no unique connected runtime thread")
	if len(matches) == 1 {
		if matches[0].Status != "connected" {
			return "", unbound
		}
		return matches[0].ThreadID, nil
	}
	if len(matches) == 0 || len(matches) > 16 {
		return "", unbound
	}
	parents := map[string]string{}
	for _, match := range matches {
		parent, err := spawnParent(match.ThreadID)
		if err != nil {
			return "", unbound
		}
		parents[match.ThreadID] = parent
	}
	root := ""
	for _, match := range matches {
		if parents[match.ThreadID] == "" {
			if root != "" {
				return "", unbound
			}
			root = match.ThreadID
		}
	}
	if root == "" {
		return "", unbound
	}
	for _, match := range matches {
		if match.ThreadID == root {
			if match.Status != "connected" {
				return "", unbound
			}
			continue
		}
		// Every descendant must chain to the root through loaded matches.
		id, reached := match.ThreadID, false
		for depth := 0; depth < len(matches); depth++ {
			parent, loaded := parents[id]
			if !loaded || parent == "" {
				break
			}
			if parent == root {
				reached = true
				break
			}
			id = parent
		}
		if !reached {
			return "", unbound
		}
	}
	return root, nil
}

// threadSpawnParent reads a thread's own session_meta record. It returns ""
// for a top-level thread and the parent for a thread_spawn agent; any other
// or unreadable source is an error rather than a guess.
func threadSpawnParent(path, threadID string) (string, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 || !ok || int(owner.Uid) != os.Getuid() {
		return "", errors.New("thread transcript is not a private regular file")
	}
	const limit = 8 << 20
	line, err := bufio.NewReaderSize(io.LimitReader(file, limit), 64<<10).ReadBytes('\n')
	if err != nil && !(errors.Is(err, io.EOF) && len(line) > 0) {
		return "", errors.New("thread session metadata unavailable")
	}
	var row struct {
		Type    string `json:"type"`
		Payload struct {
			ID     string          `json:"id"`
			Source json.RawMessage `json:"source"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &row) != nil || row.Type != "session_meta" || row.Payload.ID != threadID {
		return "", errors.New("thread session metadata does not identify this thread")
	}
	var named string
	if json.Unmarshal(row.Payload.Source, &named) == nil && named != "" {
		return "", nil
	}
	var spawned struct {
		Subagent struct {
			ThreadSpawn *struct {
				Parent string `json:"parent_thread_id"`
			} `json:"thread_spawn"`
		} `json:"subagent"`
	}
	if json.Unmarshal(row.Payload.Source, &spawned) != nil || spawned.Subagent.ThreadSpawn == nil ||
		spawned.Subagent.ThreadSpawn.Parent == "" || spawned.Subagent.ThreadSpawn.Parent == threadID {
		return "", errors.New("thread source is not a known top-level or spawned thread")
	}
	return spawned.Subagent.ThreadSpawn.Parent, nil
}
