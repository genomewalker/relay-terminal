#!/usr/bin/env python3
"""Gracefully restart Relay, optionally installing a signed candidate first.

Does not terminate relayd, terminal workers, remote agents or route listeners.
Refuses replacement if the app cannot quit or another instance appears.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import select
import subprocess
import sys
import tempfile
import time


def app_pids(app):
    executable = str(app / 'Contents/MacOS/Relay')
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    result = []
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == executable:
            result.append(int(parts[0]))
    return result


def verify(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        if plistlib.load(stream).get('CFBundleIdentifier') != 'dev.relay.terminal':
            raise ValueError('Candidate is not a Relay app bundle')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return hashlib.sha256((app / 'Contents/MacOS/Relay').read_bytes()).hexdigest()


def quit_app(app, timeout):
    pids = app_pids(app)
    if not pids:
        return
    queue = select.kqueue()
    try:
        for pid in pids:
            event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                 fflags=select.KQ_NOTE_EXIT)
            try:
                queue.control([event], 0, 0)
            except ProcessLookupError:
                pass
        subprocess.run(['/usr/bin/osascript', '-e', f'with timeout of {int(timeout)} seconds',
                        '-e', 'tell application id "dev.relay.terminal" to quit',
                        '-e', 'end timeout'], timeout=timeout + 2, check=True)
        deadline = time.monotonic() + timeout
        remaining = set(app_pids(app)) & set(pids)
        while remaining:
            duration = deadline - time.monotonic()
            if duration <= 0:
                raise RuntimeError('Relay did not quit; installation was not performed')
            events = queue.control(None, len(pids), duration)
            if not events:
                raise RuntimeError('Relay did not quit; installation was not performed')
            remaining.difference_update(event.ident for event in events)
        if app_pids(app):
            raise RuntimeError('Another Relay instance appeared; installation was not performed')
    finally:
        queue.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    update = parser.add_mutually_exclusive_group()
    update.add_argument('--candidate', type=Path, help='Signed Relay.app to install before restarting')
    update.add_argument('--preservation-root', type=Path,
                        help='Existing staged preservation receipt to apply during the restart')
    parser.add_argument('--app', type=Path, default=Path('/Applications/Relay.app'))
    parser.add_argument('--timeout', type=int, default=30)
    parser.add_argument('--replay-trace', type=Path,
                        help='New private terminal-replay-trace.log within the preservation receipt')
    args = parser.parse_args()
    if not 1 <= args.timeout <= 60:
        parser.error('timeout must be between 1 and 60 seconds')
    app = args.app.resolve()
    preservation = args.preservation_root.resolve() if args.preservation_root else None
    preservation_helper = Path(__file__).resolve().parent.parent / 'work/deploy-full-preserving.py'
    if preservation:
        info = preservation.stat()
        if app != Path('/Applications/Relay.app') or preservation.parent != Path('/private/tmp') \
                or not preservation.name.startswith('relay-interface-update-') \
                or info.st_uid != os.getuid() or info.st_mode & 0o077 \
                or not (preservation / 'baseline.json').is_file() or not preservation_helper.is_file():
            parser.error('invalid staged preservation root')
    trace = args.replay_trace.absolute() if args.replay_trace else None
    if trace and (not preservation or trace.parent != preservation or
                  trace.name != 'terminal-replay-trace.log' or trace.exists() or trace.is_symlink()):
        parser.error('replay trace must be a new file inside the private preservation receipt')
    candidate = args.candidate.resolve() if args.candidate else None
    expected = verify(preservation / 'Relay.app' if preservation else candidate or app)
    previous = verify(app)
    if candidate == app:
        parser.error('candidate must be a separate bundle')
    # The private lock prevents concurrent deployments through this command.
    import fcntl
    lock = Path(tempfile.gettempdir()) / f'relay-restart-{os.getuid()}.lock'
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if trace:
            trace_fd = os.open(trace, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.close(trace_fd)
        quit_app(app, args.timeout)
        if preservation:
            try:
                subprocess.run([sys.executable, str(preservation_helper), 'apply',
                                '--root', str(preservation), '--ui-closed'], check=True)
                if verify(app) != expected:
                    raise RuntimeError('Installed executable did not match the staged candidate')
            except BaseException:
                # The preservation helper rolls back replacement failures.
                # Reopen only the exact verified previous executable.
                if app.exists() and verify(app) == previous:
                    subprocess.run(['/usr/bin/open', '-a', str(app)], check=True)
                raise
            print('Preservation receipt:', preservation)
        elif candidate:
            if verify(candidate) != expected:
                raise RuntimeError('Candidate changed during quit; installation was not performed')
            backup = Path('/private/tmp') / ('relay-before-restart-' + time.strftime('%Y%m%d-%H%M%S') + '.app')
            if backup.exists():
                raise RuntimeError('Backup already exists; installation was not performed')
            app.rename(backup)
            try:
                candidate.rename(app)
                if verify(app) != expected:
                    raise RuntimeError('Installed executable did not match the candidate')
            except BaseException:
                if app.exists():
                    app.rename(candidate)
                backup.rename(app)
                raise
            print('Backup:', backup)
        launch = ['/usr/bin/open', '-a', str(app)]
        if trace:
            launch += ['--env', 'RELAY_REPLAY_TRACE=1', '--stderr', str(trace)]
        subprocess.run(launch, check=True)
        print('Launched:', app)
        print('Expected executable SHA256:', expected)


if __name__ == '__main__':
    main()
