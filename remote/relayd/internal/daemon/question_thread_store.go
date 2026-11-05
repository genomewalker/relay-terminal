package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// questionThreadStore keeps one private record per bound pane, so a Relay or
// relayd restart resumes the lease, the cursor and the outbox.
type questionThreadStore struct {
	dir string
}

func (store questionThreadStore) path(pane string) (string, error) {
	if !validSessionID.MatchString(pane) {
		return "", errors.New("invalid pane")
	}
	return filepath.Join(store.dir, pane+".json"), nil
}

func (store questionThreadStore) save(binding questionThreadBinding) error {
	path, err := store.path(binding.PaneID)
	if err != nil {
		return err
	}
	data, err := json.Marshal(binding)
	if err != nil {
		return err
	}
	return durableWriteFile(path, append(data, '\n'))
}

// load returns found=false when the pane has no record. A record left in
// "sending" by a crash is settled to outcome_unknown before it is returned.
func (store questionThreadStore) load(pane string) (questionThreadBinding, bool, error) {
	path, err := store.path(pane)
	if err != nil {
		return questionThreadBinding{}, false, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return questionThreadBinding{}, false, nil
	}
	if err != nil {
		return questionThreadBinding{}, false, err
	}
	var binding questionThreadBinding
	if err := json.Unmarshal(data, &binding); err != nil || binding.PaneID != pane {
		return questionThreadBinding{}, false, errors.New("invalid question thread record")
	}
	return settleQuestionOutbox(binding), true, nil
}

func (store questionThreadStore) panes() ([]string, error) {
	paths, err := filepath.Glob(filepath.Join(store.dir, "*.json"))
	if err != nil {
		return nil, err
	}
	var panes []string
	for _, path := range paths {
		if pane := strings.TrimSuffix(filepath.Base(path), ".json"); validSessionID.MatchString(pane) {
			panes = append(panes, pane)
		}
	}
	return panes, nil
}

func (store questionThreadStore) remove(pane string) error {
	path, err := store.path(pane)
	if err != nil {
		return err
	}
	return durableRemoveFile(path)
}
