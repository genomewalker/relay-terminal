package main

import (
	"encoding/json"
	"fmt"
	"github.com/relay-terminal/relayd/internal/localbroker"
	"github.com/relay-terminal/relayd/internal/protocol"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	if len(os.Args) < 5 {
		return fmt.Errorf("usage: relay-connection client|serve socket executable arguments...")
	}
	mode, socket := os.Args[1], os.Args[2]
	if mode == "serve" {
		return serve(socket, os.Args[3], os.Args[4:])
	}
	if mode != "client" {
		return fmt.Errorf("invalid broker mode")
	}
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		cmd := exec.Command(executable, append([]string{"serve", socket}, os.Args[3:]...)...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
		if err != nil {
			return err
		}
		defer null.Close()
		cmd.Stdin = null
		cmd.Stdout = null
		cmd.Stderr = null
		if err := cmd.Start(); err != nil {
			return err
		}
		_ = cmd.Process.Release()
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			conn, err = net.DialTimeout("unix", socket, 100*time.Millisecond)
			if err == nil {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
		if err != nil {
			return err
		}
	}
	defer conn.Close()
	go func() { _, _ = io.Copy(conn, os.Stdin); _ = conn.Close() }()
	_, err = io.Copy(os.Stdout, conn)
	return err
}
func serve(socket, executable string, args []string) error {
	// The caller supplies a verified private directory. Check it again here.
	info, err := os.Lstat(filepath.Dir(socket))
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || info.Mode().Perm() != 0700 || stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("broker directory must be private and owned by current user")
	}
	lock, err := os.OpenFile(socket+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return err
	}
	if old, err := os.Lstat(socket); err == nil {
		owner, ok := old.Sys().(*syscall.Stat_t)
		if !ok || old.Mode()&os.ModeSocket == 0 || owner.Uid != uint32(os.Getuid()) {
			return fmt.Errorf("invalid stale broker socket")
		}
		if err := os.Remove(socket); err != nil {
			return err
		}
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	_ = os.Chmod(socket, 0600)
	cmd := exec.Command(executable, args...)
	input, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	startup := time.AfterFunc(10*time.Second, func() { _ = cmd.Process.Kill() })
	ready, err := protocol.ReadFrame(output)
	startup.Stop()
	if err != nil {
		return err
	}
	var status protocol.StatusPayload
	if protocol.DecodeJSON(ready, &status) != nil || status.State != "ready" {
		return fmt.Errorf("node did not become ready")
	}
	supported := false
	for _, capability := range status.Capabilities {
		if capability == "node_mux_v2" {
			supported = true
		}
	}
	if !supported {
		return fmt.Errorf("persistent broker requires node_mux_v2")
	}
	// The broker owns this transport incarnation. Viewer fragment IDs and
	// negotiation must never leak into the retained remote stream.
	remoteReader := protocol.NewFragmentReader(output)
	for _, capability := range status.Capabilities {
		if capability == "wire_fragments_v1" {
			negotiation := protocol.Frame{Type: protocol.Capabilities, Payload: []byte(`{"wire_fragments":true}`)}
			if err := protocol.NewWriter(input).Write(negotiation); err != nil {
				return err
			}
			remoteReader.Enabled = true
			break
		}
	}
	var lastPong atomic.Int64
	lastPong.Store(time.Now().UnixNano())
	broker := localbroker.New(input, ready)
	defer broker.Close()
	go func() {
		for {
			frame, err := remoteReader.Read()
			if err != nil {
				broker.Close()
				_ = listener.Close()
				return
			}
			if frame.Type == protocol.Pong {
				lastPong.Store(time.Now().UnixNano())
			}
			broker.RemoteFrame(frame)
		}
	}()
	// Keepalives remain active with no GUI; a dead SSH stream exits and removes
	// the socket, allowing the next attachment to establish a fresh incarnation.
	go func() {
		for {
			time.Sleep(2 * time.Second)
			if time.Since(time.Unix(0, lastPong.Load())) > 6*time.Second {
				_ = cmd.Process.Kill()
				return
			}
			payload, _ := json.Marshal(time.Now().UnixNano())
			if broker.Ping(payload) != nil {
				return
			}
		}
	}()
	for {
		_ = listener.(*net.UnixListener).SetDeadline(time.Now().Add(10 * time.Minute))
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		_ = broker.Serve(conn)
	}
}
