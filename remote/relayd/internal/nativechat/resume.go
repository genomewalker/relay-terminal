package nativechat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
)

type ResumePlan struct {
	Source      Identity
	Session     string
	CWD         string
	Model       string
	AccountRoot string
}

// ReadResumePlan permits an explicit saved-conversation launch only after the
// original worker AND provider are positively observed gone. This is not a
// retirement or background-job preservation capability. It sends no input.
func ReadResumePlan(root string, source Identity, accountRoot string, k Kernel) (ResumePlan, error) {
	var plan ResumePlan
	if k.ProcessGone == nil || !filepath.IsAbs(accountRoot) {
		return plan, errors.New("native resume requires exact process and account observations")
	}
	dir, e := instanceDirectory(root, source)
	if e != nil {
		return plan, e
	}
	data, e := privateRead(filepath.Join(dir, "descriptor.json"), 16<<10)
	if e != nil {
		return plan, e
	}
	if _, e = DecodeObject(data, 16<<10); e != nil {
		return plan, e
	}
	var descriptor Descriptor
	if json.Unmarshal(data, &descriptor) != nil || descriptor.Version != 1 || descriptor.Identity != source || descriptor.ProviderPID <= 0 || descriptor.ProviderStart == "" {
		return plan, errors.New("saved native process identity is incomplete")
	}
	for _, owner := range []struct {
		pid   int
		start string
	}{{descriptor.PID, descriptor.ProcessStart}, {descriptor.ProviderPID, descriptor.ProviderStart}} {
		gone, err := k.ProcessGone(owner.pid, owner.start)
		if err != nil || !gone {
			return plan, errors.New("source worker or provider remains active or uncertain; reconnect instead")
		}
	}
	data, e = privateRead(filepath.Join(dir, "snapshot.json"), MaxTransportBytes)
	if e != nil {
		return plan, e
	}
	if _, e = DecodeObject(data, MaxTransportBytes); e != nil {
		return plan, e
	}
	var snapshot Snapshot
	if json.Unmarshal(data, &snapshot) != nil || snapshot.Version != 1 || snapshot.Identity != source || !validID(snapshot.SessionID) ||
		snapshot.AccountRoot != accountRoot || !filepath.IsAbs(snapshot.CWD) {
		return plan, errors.New("saved native conversation does not match this account and workspace")
	}
	if len(snapshot.Requests) > 0 {
		return plan, errors.New("saved native conversation has unresolved provider requests")
	}
	if e = settledReceiptFile(filepath.Join(dir, "actions.jsonl")); e != nil {
		return plan, e
	}
	return ResumePlan{Source: source, Session: snapshot.SessionID, CWD: snapshot.CWD, Model: snapshot.Model, AccountRoot: accountRoot}, nil
}
func settledReceiptFile(path string) error {
	data, e := privateRead(path, 32<<20)
	if e != nil {
		return e
	}
	if len(data) > 0 && data[len(data)-1] != 10 {
		return errors.New("receipt journal has an incomplete final record")
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), 256<<10)
	receipts := map[string]Receipt{}
	count := 0
	for scanner.Scan() {
		count++
		if count > MaxReceipts*2 {
			return errors.New("receipt journal exceeds supported resume bound")
		}
		line := scanner.Bytes()
		if _, e := DecodeObject(line, 256<<10); e != nil {
			return e
		}
		var r Receipt
		if json.Unmarshal(line, &r) != nil || !validID(r.ID) || r.Digest == "" {
			return errors.New("invalid saved receipt")
		}
		if prior, ok := receipts[r.ID]; ok && prior.Digest != r.Digest {
			return errors.New("saved receipt identity changed")
		}
		receipts[r.ID] = r
	}
	if e = scanner.Err(); e != nil {
		return e
	}
	for _, r := range receipts {
		if r.State != "sent" && r.State != "rejected" {
			return errors.New("saved action outcome is unresolved; do not relaunch automatically")
		}
	}
	return nil
}
func sessionLease(root, provider, account, session string) (*os.File, error) {
	if !validID(session) || !filepath.IsAbs(account) {
		return nil, errors.New("native session lease requires an exact account and session")
	}
	dir := filepath.Join(root, "native-sessions")
	if e := privateDirectory(dir); e != nil {
		return nil, e
	}
	path := filepath.Join(dir, stableID("session", provider+":"+account+":"+session)+".lock")
	f, e := os.OpenFile(path, os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0600)
	if e != nil {
		return nil, e
	}
	if e = unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); e != nil {
		_ = f.Close()
		return nil, fmt.Errorf("native session is already owned: %w", e)
	}
	return f, nil
}
