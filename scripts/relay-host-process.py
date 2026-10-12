#!/usr/bin/env python3
"""Relay host job adapter: reconnect reads, never replay ambiguous execution."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

LIMIT = 1_048_576
TERMINAL = {'exited', 'failed', 'unknown_after_daemon_restart'}


class HostTransport:
    def __init__(self, host):
        self.host = host
        self.headers = None

    def refresh_token(self):
        raw = subprocess.check_output([
            '/Applications/Relay.app/Contents/MacOS/relay-mcp',
            '--use-relay-token', '--print-http-headers'], timeout=10)
        token = json.loads(raw)['Authorization'].removeprefix('Bearer ')
        self.headers = {'X-Relay-Token': token, 'Content-Type': 'application/json'}

    def request(self, job_id, operation, **values):
        if self.headers is None:
            self.refresh_token()
        body = dict(host=self.host, request_id='rpc-' + uuid.uuid4().hex,
                    operation=operation, job_id=job_id, **values)
        req = urllib.request.Request('http://127.0.0.1:47471/api/host/request',
            data=json.dumps(body).encode(), headers=self.headers)
        try:
            with urllib.request.urlopen(req, timeout=25) as response:
                raw = response.read(LIMIT + 1)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                self.headers = None  # refresh on a later read, never retry this mutation
            raise
        if len(raw) > LIMIT:
            raise ValueError('Relay response exceeds adapter limit')
        answer = json.loads(raw)
        if answer.get('error'):
            raise RuntimeError(answer['error'])
        return answer['result']


class ListenerCheckpoint:
    def __init__(self, host, argv):
        root = Path.home() / '.local/state/relay/host-adapters'
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.check_private(root, directory=True)
        identity = hashlib.sha256(json.dumps([host, argv]).encode()).hexdigest()
        self.path = root / (identity + '.json')
        self.lock_fd = os.open(str(root / (identity + '.lock')),
                               os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.state = {}
        if self.path.exists() or self.path.is_symlink():
            self.check_private(self.path)
            self.state = json.loads(self.path.read_text())
            if not isinstance(self.state, dict):
                raise ValueError('invalid listener checkpoint')
        self.job_id = self.state.get('job_id', 'job-' + uuid.uuid4().hex)
        if not isinstance(self.job_id, str) or not self.job_id.startswith('job-'):
            raise ValueError('invalid saved listener job')
        for key in ('stdout_offset', 'stderr_offset'):
            value = self.state.get(key, 0)
            if type(value) is not int or value < 0:
                raise ValueError('invalid saved listener offset')

    @staticmethod
    def check_private(path, directory=False):
        info = path.lstat()
        kind = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
        if not kind or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('listener checkpoint must be private')
        if not directory and info.st_size > 16384:
            raise ValueError('listener checkpoint exceeds limit')

    def save(self):
        self.state['job_id'] = self.job_id
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix='.listener-')
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(self.state, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(tmp, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def rotate_terminal_job(self):
        # Preserve the previous pointer as evidence, never erase its job reservation.
        os.replace(self.path, self.path.with_name(self.path.name + '.previous-' + self.job_id))
        self.job_id = 'job-' + uuid.uuid4().hex
        self.state = {}
        self.save()


def emit(event):
    print(json.dumps(event), flush=True)


def resume_ready(transport, checkpoint):
    # Ready is transport metadata, not a replayed message. Read the original first
    # line from the SAME running job to restore its exact mailbox after reconnect.
    answer = transport.request(checkpoint.job_id, 'status', stdout_offset=0,
                               stderr_offset=checkpoint.state.get('stderr_offset', 0))
    record = answer['job']
    if record['state'] != 'running':
        raise RuntimeError('Saved listener is not running; outcome unresolved')
    first = base64.b64decode(answer.get('stdout') or '', validate=True).split(b'\n', 1)[0]
    if len(first) > 131072:
        raise ValueError('invalid listener ready frame')
    if not first:
        return False  # reservation exists but helper has not published readiness yet
    ready = json.loads(first)
    if ready.get('type') != 'ready' or ready.get('pid') != record.get('pid'):
        raise RuntimeError('Saved listener mailbox identity does not match its job')
    emit(ready)
    return True


def wait_parent_ack(offset):
    # Parent acknowledges only after a durable receipt reservation/delivery. Pipe
    # flush is not acknowledgment: if the parent disappears, resume this offset.
    if not select.select([sys.stdin.buffer], [], [], 60)[0]:
        raise RuntimeError('Route receipt checkpoint acknowledgment timed out')
    raw = sys.stdin.buffer.readline(4097)
    if not raw:
        raise RuntimeError('Route detached before receipt acknowledgment')
    if len(raw) > 4096:
        raise ValueError('oversized route acknowledgment')
    value = json.loads(raw)
    if type(value.get('ack_offset')) is not int or value['ack_offset'] != offset:
        raise ValueError('route acknowledgment does not match delivered event')


def listen(transport, argv, receipt_checkpoints=False):
    checkpoint = ListenerCheckpoint(transport.host, argv)
    def detach(*unused):
        os._exit(0)  # preserve host job, offsets and reply socket across pipe outages
    signal.signal(signal.SIGUSR1, detach)
    def stop(*unused):
        try:
            transport.request(checkpoint.job_id, 'cancel')
        finally:
            os._exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)

    resumed = False
    if checkpoint.state:
        snapshot = transport.request(checkpoint.job_id, 'status')
        existing = snapshot['job']
        if existing['state'] in ('exited', 'failed'):
            checkpoint.rotate_terminal_job()
        elif existing['state'] == 'running':
            resumed = True
        elif (existing['state'] == 'unknown_after_daemon_restart'
              and snapshot.get('process_state') in ('absent', 'replaced')
              and checkpoint.state.get('purpose') == 'peer_listener'):
            # Restart only this approved inbox, not a project execution or send.
            # Its argv-derived ledger key binds the same recipient and listener
            # payload; the old unresolved job and receipts remain untouched.
            checkpoint.rotate_terminal_job()
        else:
            raise RuntimeError('Saved listener outcome unknown after daemon restart; explicit recovery required, no automatic replay')
    checkpoint.state['purpose'] = 'peer_listener'
    checkpoint.save()
    if not resumed:
        # Exactly one mutation per invocation. Saved reservation makes an ambiguous
        # launch inspectable; a later invocation must consult status, not launch.
        started = transport.request(checkpoint.job_id, 'exec', argv=argv, keep_stdin=True)
        if started['state'] != 'running':
            raise RuntimeError('Listener launch did not establish running state: ' + started['state'])
    else:
        resume_ready(transport, checkpoint)

    offset = checkpoint.state.get('stdout_offset', 0)
    error_offset = checkpoint.state.get('stderr_offset', 0)
    pending = b''
    failures = 0
    while True:
        try:
            result = transport.request(checkpoint.job_id, 'status', stdout_offset=offset,
                                       stderr_offset=error_offset, wait_millis=15000)
        except (OSError, RuntimeError, urllib.error.URLError) as error:
            failures += 1
            # Do not leak HTTP bodies, tokens or argv into route status.
            category = 'permission_required' if isinstance(error, urllib.error.HTTPError) and error.code in (401, 403) else 'transport_unavailable'
            emit(dict(type='transport_status', state=category,
                      message='Waiting for Relay permission' if category == 'permission_required' else 'Relay host channel unavailable; listener preserved'))
            time.sleep(min(15, 2 ** min(failures, 4)))
            continue
        if failures:
            if result['job']['state'] == 'running':
                resume_ready(transport, checkpoint)
            failures = 0
        output = base64.b64decode(result.get('stdout') or '', validate=True)
        errors = base64.b64decode(result.get('stderr') or '', validate=True)
        if result['stdout_offset'] != offset + len(output):
            raise ValueError('Relay output offset mismatch')
        if errors:
            sys.stderr.buffer.write(errors)
            sys.stderr.buffer.flush()
        offset = result['stdout_offset']
        error_offset = result['stderr_offset']
        pending += output
        while b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            if len(line) > 131072:
                raise ValueError('oversized listener event')
            event = json.loads(line)
            event_offset = offset - len(pending)
            if receipt_checkpoints:
                emit(dict(type='host_event', event=event, offset=event_offset))
                wait_parent_ack(event_offset)
            else:
                # Old supervisors keep the legacy stream while a new generation
                # is staged. Their checkpoint semantics are deliberately unchanged.
                emit(event)
            checkpoint.state.update(stdout_offset=event_offset, stderr_offset=error_offset)
            checkpoint.save()
        if len(pending) > 131072:
            raise ValueError('unterminated listener event exceeds limit')
        if result['job']['state'] in TERMINAL and not output and not errors:
            if pending:
                raise RuntimeError('Listener ended with an incomplete event; checkpoint retained')
            return result['job'].get('exit_code', 1)


def main():
    host, mode, *argv = sys.argv[1:]
    transport = HostTransport(host)
    if mode == 'listen':
        receipt_checkpoints = bool(argv and argv[0] == '--receipt-checkpoints')
        if receipt_checkpoints:
            argv = argv[1:]
        return listen(transport, argv, receipt_checkpoints)
    if mode != 'send':
        raise ValueError('unsupported host adapter mode')
    # Outgoing sends are NEVER retried, including HTTP failure after dispatch.
    job_id = 'job-' + uuid.uuid4().hex
    started = transport.request(job_id, 'exec', argv=argv,
        stdin=base64.b64encode(sys.stdin.buffer.read(65537)).decode())
    if started['state'] not in ('running', 'exited'):
        raise RuntimeError('Send execution outcome unresolved: ' + started['state'])
    offset = error_offset = 0
    while True:
        result = transport.request(job_id, 'status', stdout_offset=offset,
                                   stderr_offset=error_offset, wait_millis=15000)
        for name, stream in (('stdout', sys.stdout.buffer), ('stderr', sys.stderr.buffer)):
            data = base64.b64decode(result.get(name) or '', validate=True)
            if data:
                stream.write(data)
                stream.flush()
        offset, error_offset = result['stdout_offset'], result['stderr_offset']
        if result['job']['state'] in TERMINAL and not result.get('stdout') and not result.get('stderr'):
            return result['job'].get('exit_code', 1)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Relay host transport: ' + str(error), file=sys.stderr)
        sys.exit(1)
