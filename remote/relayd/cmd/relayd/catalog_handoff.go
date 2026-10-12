package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/relay-terminal/relayd/internal/daemon"
)

// Offline only: hold exactly the lock used by daemon.Serve for the whole merge.
// Failure never starts a helper or signals the process holding that lock.
func runPreserveCatalog(arguments []string) {
	flags := flag.NewFlagSet("preserve-catalog", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "supervisor socket")
	snapshot := flags.String("snapshot", "", "private safe catalog snapshot")
	capabilities := flags.Bool("capabilities", false, "report offline handoff protocol")
	verify := flags.Bool("verify", false, "verify retained metadata without mutation")
	validate := flags.Bool("validate", false, "validate private snapshot before retirement")
	_ = flags.Parse(arguments)
	if *capabilities {
		fmt.Println(`{"catalog_handoff_protocol":1,"catalog_handoff_validate":true}`)
		return
	}
	if *snapshot == "" || flags.NArg() != 0 {
		fatal("private snapshot required")
	}
	if err := catalogHandoffMode(*socket, *snapshot, *verify, *validate); err != nil {
		fatal(err.Error())
	}
	fmt.Println("Catalog metadata preserved without launching workers")
}

func preserveCatalogOffline(socket, snapshot string) error {
	return preserveCatalogOfflineMode(socket, snapshot, false)
}

func preserveCatalogOfflineMode(socket, snapshot string, verify bool) error {
	return catalogHandoffMode(socket, snapshot, verify, false)
}

func catalogHandoffMode(socket, snapshot string, verify, validate bool) error {
	if filepath.Clean(socket) != filepath.Clean(defaultSocket()) {
		return errors.New("catalog import requires this profile's default supervisor socket")
	}
	if !validate {
		lock, err := daemon.OpenPrivateFile(socket+".lock", syscall.O_CREAT|syscall.O_RDWR)
		if err != nil {
			return err
		}
		defer lock.Close()
		if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			return errors.New("catalog import deferred while supervisor lock is held")
		}
		defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	}
	fd, err := syscall.Open(snapshot, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), snapshot)
	defer file.Close()
	before, err := file.Stat()
	if err != nil {
		return err
	}
	identity, ok := before.Sys().(*syscall.Stat_t)
	if !ok || int(identity.Uid) != os.Getuid() || !before.Mode().IsRegular() || before.Mode().Perm()&0077 != 0 || identity.Nlink != 1 || before.Size() > 8<<20 {
		return errors.New("private bounded single-link snapshot required")
	}
	data, err := io.ReadAll(io.LimitReader(file, (8<<20)+1))
	if err != nil {
		return err
	}
	after, err := file.Stat()
	if err != nil {
		return err
	}
	if len(data) > 8<<20 || before.Size() != int64(len(data)) || before.Size() != after.Size() || before.ModTime() != after.ModTime() {
		return errors.New("snapshot changed while reading")
	}
	var value daemon.CatalogSnapshot
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("one catalog snapshot required")
	}
	if err := daemon.ValidateCatalogSnapshot(value); err != nil {
		return err
	}
	if validate {
		return nil
	}
	server := daemon.NewServer()
	if verify {
		current, err := server.CatalogSnapshot()
		if err != nil {
			return err
		}
		if current.NodeID != value.NodeID || current.Schema != value.Schema {
			return errors.New("catalog node/schema changed")
		}
		entries := make(map[string]daemon.CatalogPane)
		for _, pane := range current.Panes {
			entries[pane.PaneID] = pane
		}
		for _, original := range value.Panes {
			pane, exists := entries[original.PaneID]
			// Runtime liveness and cursors are intentionally independently validated.
			if !exists || pane.NodeID != original.NodeID || pane.WorkspaceID != original.WorkspaceID || pane.TabID != original.TabID || pane.ParentPaneID != original.ParentPaneID || pane.Title != original.Title || pane.ContentKind != original.ContentKind || pane.Command != original.Command || pane.Directory != original.Directory || !pane.CreatedAt.Equal(original.CreatedAt) || pane.WorkerPID != original.WorkerPID || pane.ShellPID != original.ShellPID {
				return errors.New("saved pane metadata not retained")
			}
		}
		return nil
	}
	return server.PreserveCatalogSnapshot(value)
}
