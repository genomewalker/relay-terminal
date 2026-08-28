package main

import (
	"flag"
	"fmt"
	"os"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
	"github.com/relay-terminal/relayd/internal/protocol"
)

type liveSupervisor struct {
	Status  protocol.StatusPayload
	PeerPID int
}

func runLiveStatus(arguments []string) {
	flags := flag.NewFlagSet("live-status", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "supervisor socket")
	_ = flags.Parse(arguments)

	live, err := inspectSupervisor(*socket)
	if err != nil {
		fmt.Println("RELAYD_STOPPED")
		return
	}
	pid := live.Status.SupervisorPID
	if live.PeerPID > 0 {
		pid = live.PeerPID
	}
	version := live.Status.Version
	if version == "" {
		version = "unknown"
	}
	fmt.Printf("RELAYD_LIVE\t%s\t%d\t%d\n", version, live.Status.ProtocolVersion, pid)
}

func runUpgradeSupervisor(arguments []string) {
	flags := flag.NewFlagSet("upgrade-supervisor", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "supervisor socket")
	legacy := flags.String("legacy-socket", legacySocket(), "legacy supervisor socket")
	force := flags.Bool("force", false, "replace the validated supervisor even when its version matches")
	_ = flags.Parse(arguments)

	current, currentErr := inspectSupervisor(*socket)
	if !*force && currentErr == nil && current.Status.Version == relaydVersion &&
		current.Status.ProtocolVersion == supervisorProtocolVersion {
		fmt.Printf("relayd supervisor %s is current\n", relaydVersion)
		return
	}

	if currentErr == nil {
		if err := stopValidatedSupervisor(*socket, current); err != nil {
			fatal("cannot replace existing supervisor: " + err.Error())
		}
	}
	if *legacy != "" && *legacy != *socket {
		if old, err := inspectSupervisor(*legacy); err == nil {
			if err := stopValidatedSupervisor(*legacy, old); err != nil {
				fatal("cannot retire legacy supervisor: " + err.Error())
			}
		}
	}

	connection, err := connectOrStart(*socket)
	if err != nil {
		fatal("cannot start upgraded supervisor: " + err.Error())
	}
	_ = connection.Close()

	verificationDeadline := time.Now().Add(8 * time.Second)
	var live liveSupervisor
	for {
		live, err = inspectSupervisor(*socket)
		if err == nil && live.Status.Version == relaydVersion &&
			live.Status.ProtocolVersion == supervisorProtocolVersion {
			break
		}
		if time.Now().After(verificationDeadline) {
			if err != nil {
				fatal("upgraded supervisor did not answer: " + err.Error())
			}
			fatal(fmt.Sprintf("supervisor verification failed: got %s protocol %d, want %s protocol %d",
				live.Status.Version, live.Status.ProtocolVersion, relaydVersion, supervisorProtocolVersion))
		}
		time.Sleep(50 * time.Millisecond)
	}
	fmt.Printf("relayd supervisor upgraded to %s; pane workers were preserved\n", relaydVersion)
}

func inspectSupervisor(socket string) (liveSupervisor, error) {
	var live liveSupervisor
	connection, err := dialDaemon(socket, 250*time.Millisecond)
	if err != nil {
		return live, err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	_, peerPID, err := daemon.PeerCredentials(connection)
	if err != nil {
		return live, err
	}
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: "_probe", Probe: true,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return live, err
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.Status {
		return live, fmt.Errorf("invalid relayd probe response")
	}
	if err := protocol.DecodeJSON(frame, &live.Status); err != nil || live.Status.State != "ready" {
		return live, fmt.Errorf("relayd is not ready")
	}
	live.PeerPID = peerPID
	if live.PeerPID > 0 && live.Status.SupervisorPID > 0 && live.PeerPID != live.Status.SupervisorPID {
		return liveSupervisor{}, fmt.Errorf("supervisor pid does not match its socket peer")
	}
	return live, nil
}

func stopValidatedSupervisor(socket string, live liveSupervisor) error {
	pid := live.PeerPID
	if pid <= 1 {
		pid = live.Status.SupervisorPID
	}
	if pid <= 1 {
		return fmt.Errorf("supervisor did not expose a valid pid")
	}
	if err := validateSupervisorProcess(pid, socket, os.Getuid()); err != nil {
		return err
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return err
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		current, err := inspectSupervisor(socket)
		if err == nil && (current.PeerPID > 0 && current.PeerPID != pid ||
			current.PeerPID <= 0 && current.Status.SupervisorPID != pid) {
			return nil
		}
		if available, lockErr := supervisorLockAvailable(socket); lockErr == nil && available {
			return nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	return fmt.Errorf("supervisor pid %d did not stop after SIGTERM", pid)
}

func supervisorLockAvailable(socket string) (bool, error) {
	lockFile, err := daemon.OpenPrivateFile(socket+".lock", syscall.O_CREAT|syscall.O_RDWR)
	if err != nil {
		return false, err
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return false, nil
	}
	_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
	return true, nil
}
