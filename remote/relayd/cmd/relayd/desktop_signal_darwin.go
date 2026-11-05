//go:build darwin

package main

import (
	"context"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

// desktopSignalContext also observes Darwin's kernel signal counter. A TERM
// delivered while a Go process is SIGSTOP'ed can be absent from os/signal after
// SIGCONT; kqueue retains it. Register before the listener advertises readiness.
func desktopSignalContext() (context.Context, func(), error) {
	base, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	ctx, cancel := context.WithCancel(base)
	fd, err := unix.Kqueue()
	if err != nil {
		cancel()
		stopSignals()
		return nil, nil, err
	}
	unix.CloseOnExec(fd)
	changes := []unix.Kevent_t{
		{Ident: uint64(syscall.SIGTERM), Filter: unix.EVFILT_SIGNAL, Flags: unix.EV_ADD | unix.EV_CLEAR},
		{Ident: uint64(syscall.SIGINT), Filter: unix.EVFILT_SIGNAL, Flags: unix.EV_ADD | unix.EV_CLEAR},
		{Ident: 1, Filter: unix.EVFILT_USER, Flags: unix.EV_ADD | unix.EV_CLEAR},
	}
	if _, err := unix.Kevent(fd, changes, nil, nil); err != nil {
		unix.Close(fd)
		cancel()
		stopSignals()
		return nil, nil, err
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		events := make([]unix.Kevent_t, 3)
		for {
			n, err := unix.Kevent(fd, nil, events, nil)
			if err == syscall.EINTR {
				continue
			}
			if err != nil {
				cancel()
				return
			}
			for _, event := range events[:n] {
				if event.Filter == unix.EVFILT_USER {
					return
				}
				if event.Filter == unix.EVFILT_SIGNAL && event.Data > 0 && (event.Ident == uint64(syscall.SIGTERM) || event.Ident == uint64(syscall.SIGINT)) {
					cancel()
					return
				}
			}
		}
	}()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			stopSignals()
			select {
			case <-done:
			default:
				_, _ = unix.Kevent(fd, []unix.Kevent_t{{Ident: 1, Filter: unix.EVFILT_USER, Fflags: unix.NOTE_TRIGGER}}, nil, nil)
				<-done
			}
			// Only this closure closes fd, after the watcher has stopped, so no
			// delayed wake can address a reused descriptor.
			unix.Close(fd)
		})
	}
	return ctx, stop, nil
}
