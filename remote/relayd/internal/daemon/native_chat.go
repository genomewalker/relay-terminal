package daemon

import (
	"context"
	"errors"
	"github.com/relay-terminal/relayd/internal/nativechat"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// NativeChatKernel observes this host; persisted UI locators confer no authority.
func NativeChatKernel() nativechat.Kernel {
	return nativechat.Kernel{ProcessStart: processStartIdentity, PeerCredentials: PeerCredentials, ProcessGone: nativeProcessGone}
}
func ServeNativeChat(ctx context.Context, c nativechat.RunConfig) error {
	c.Kernel = NativeChatKernel()
	return nativechat.Serve(ctx, c)
}

// CallNativeChat forwards only to the exact kernel-bound worker on this host.
// The UI and Miko share this path; neither supplies an authority-bearing role.
func CallNativeChat(data []byte) (nativechat.RPCResponse, error) {
	request, err := nativechat.DecodeRPC(data)
	if err != nil {
		return nativechat.RPCResponse{}, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nativechat.RPCResponse{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	return nativechat.Call(ctx, filepath.Join(home, ".local", "share", "relay"), request, NativeChatKernel())
}

func nativeProcessGone(pid int, expected string) (bool, error) {
	if pid <= 0 || expected == "" {
		return false, errors.New("incomplete native process identity")
	}
	actual, err := processStartIdentity(pid)
	if err == nil {
		return actual != expected, nil
	}
	if signalErr := syscall.Kill(pid, 0); signalErr == syscall.ESRCH {
		return true, nil
	}
	return false, err
}
