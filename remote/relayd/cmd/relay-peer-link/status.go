package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/relay-terminal/relayd/internal/peernet"
)

// statusFile is an atomic metadata snapshot for Relay's future network view.
// It is not a delivery ledger: it contains no payloads, tokens or message queue.
type statusFile struct {
	path          string
	Schema        int    `json:"schema"`
	PID           int    `json:"pid"`
	Host          string `json:"host"`
	LocalName     string `json:"localName"`
	LocalSession  string `json:"localSession"`
	RemoteName    string `json:"remoteName"`
	RemoteSession string `json:"remoteSession"`
	State         string `json:"state"`
	UpdatedAt     string `json:"updatedAt"`
	Attempt       int    `json:"attempt"`
	Error         string `json:"error,omitempty"`
	RTTMillis     int64  `json:"rttMillis"`
	LastMessageID string `json:"lastMessageId,omitempty"`
	LastReceipt   string `json:"lastReceipt,omitempty"`
}

func newStatus(home, host, local, localSession, remote, remoteSession string) (*statusFile, error) {
	dir := filepath.Join(home, ".local", "state", "relay", "peer-network")
	if e := os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	info, e := os.Lstat(dir)
	if e != nil {
		return nil, e
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("status directory must be private")
	}
	return &statusFile{path: filepath.Join(dir, fmt.Sprintf("%d.json", os.Getpid())), Schema: 1, PID: os.Getpid(), Host: host, LocalName: local, LocalSession: localSession, RemoteName: remote, RemoteSession: remoteSession, State: "offline"}, nil
}
func (s *statusFile) write() {
	s.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	b, e := json.Marshal(s)
	if e != nil {
		return
	}
	f, e := os.CreateTemp(filepath.Dir(s.path), ".status-")
	if e != nil {
		fmt.Fprintln(os.Stderr, "peer status unavailable:", e)
		return
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, e = f.Write(b); e == nil {
		e = f.Close()
	}
	if e == nil {
		e = os.Rename(f.Name(), s.path)
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, "peer status unavailable:", e)
	}
}
func (s *statusFile) set(state, err string, attempt int) {
	s.State = state
	s.Error = err
	s.Attempt = attempt
	s.write()
}
func (s *statusFile) observe(e peernet.Event) {
	s.State = e.State
	s.RTTMillis = e.RTTMillis
	if e.MessageID != "" {
		s.LastMessageID = e.MessageID
		s.LastReceipt = e.Receipt
	}
	s.write()
}
