#!/usr/bin/env python3
"""Fresh, read-only Codex frontend correlation probe. Does not install bindings.

Capture before a marker is emitted by the provider, then verify it in fresh
native markdown deltas and fresh bytes of one pinned transcript. No cwd,
environment, loaded-thread list, startup time, or historical text inference.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('discovery', ROOT / 'Sources/Relay/Resources/Rotation/agent_conversation.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def file_pin(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('Source is not an owner-controlled regular file')
    return [info.st_dev, info.st_ino]


def connect(path):
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)
    db.execute('PRAGMA query_only=ON')
    db.set_progress_handler(lambda: 1 if time.monotonic() > deadline[0] else 0, 1000)
    return db


deadline = [time.monotonic() + 8]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['begin', 'finish'])
parser.add_argument('--record', type=Path, required=True)
parser.add_argument('--pane')
parser.add_argument('--transcript', type=Path)
parser.add_argument('--logs', type=Path, default=Path.home() / '.codex/logs_2.sqlite')
parser.add_argument('--daemon', type=Path)
args = parser.parse_args()

if args.action == 'begin':
    if not args.pane or not args.transcript or not args.daemon:
        parser.error('begin requires exact pane, transcript and installed Relay daemon')
    path = args.transcript.resolve(strict=True)
    logs = args.logs.resolve(strict=True)
    root = d.root_for_pane(args.pane)
    pid, provider = d.agent(root)
    if provider != 'codex':
        raise ValueError('Exact pane does not contain Codex')
    daemon = args.daemon.resolve(strict=True)
    native_start = d.native_process_start(str(daemon), args.pane, pid, provider)
    if native_start is None:
        raise ValueError('No kernel-verified native pane incarnation')
    with connect(logs) as db:
        row = db.execute('SELECT id, process_uuid, ts FROM logs WHERE process_uuid LIKE ? ORDER BY id DESC LIMIT 1', ('pid:' + str(pid) + ':%',)).fetchone()
    if not row or time.time() - row[2] > 120:
        raise ValueError('No fresh native process log')
    record = dict(version=2, pane=args.pane, pid=pid, root=root,
                  daemon=str(daemon), native_start=native_start,
                  process_start=d.identity(pid), root_start=d.identity(root),
                  transcript=str(path), transcript_pin=file_pin(path),
                  transcript_offset=path.stat().st_size, session=d.metadata(path, 'codex'),
                  logs=str(logs), logs_pin=file_pin(logs), process_uuid=row[1],
                  log_offset=row[0], captured_at=time.time(),
                  marker='RELAY_FRONTEND_PROBE_' + uuid.uuid4().hex)
    if not record['session']:
        raise ValueError('Invalid exact transcript metadata')
    fd = os.open(args.record, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(record, f)
    print(json.dumps({'marker': record['marker'], 'pid': pid, 'session': record['session']}))
else:
    pin = file_pin(args.record)
    fd = os.open(args.record, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as f:
        info = os.fstat(f.fileno())
        if [info.st_dev, info.st_ino] != pin or info.st_mode & 0o077:
            raise ValueError('Probe record changed or is not private')
        raw = f.read(65537)
    if len(raw) > 65536 or file_pin(args.record) != pin:
        raise ValueError('Probe record changed or exceeds bound')
    record = json.loads(raw)
    if record.get('version') != 2:
        raise ValueError('Probe lacks kernel incarnation evidence; capture a new probe')
    if not 0 <= time.time() - record['captured_at'] <= 120:
        raise ValueError('Probe expired')
    def recheck():
        if d.root_for_pane(record['pane']) != record['root'] or d.agent(record['root']) != (record['pid'], 'codex'):
            raise ValueError('Pane ancestry changed')
        if d.identity(record['pid']) != record['process_start'] or d.identity(record['root']) != record['root_start']:
            raise ValueError('Process incarnation changed')
        if d.native_process_start(record['daemon'], record['pane'], record['pid'], 'codex') != record['native_start']:
            raise ValueError('Kernel pane incarnation changed')
        for key in ['transcript', 'logs']:
            if file_pin(Path(record[key])) != record[key + '_pin']:
                raise ValueError('Source incarnation changed')
        if d.metadata(Path(record['transcript']), 'codex') != record['session']:
            raise ValueError('Transcript session changed')
    recheck()
    chunks = []
    retained = 0
    last_log_id = record['log_offset']
    with connect(Path(record['logs'])) as db:
        rows = db.execute('SELECT id, ts, substr(feedback_log_body,1,262145) FROM logs WHERE process_uuid=? AND id>? AND target=? ORDER BY id LIMIT 4097', (record['process_uuid'], record['log_offset'], 'codex_tui::markdown_stream'))
        for count, (ident, ts, body) in enumerate(rows, 1):
            retained += len(body.encode())
            if count > 4096 or retained > 1 << 20 or len(body) > 262144:
                raise ValueError('Fresh log window exceeds bound')
            if ts < int(record['captured_at']) or not body.startswith('push_delta: '):
                continue
            try:
                chunk = json.loads(body[len('push_delta: '):])
                if isinstance(chunk, str):
                    chunks.append(chunk)
                    last_log_id = ident
            except ValueError:
                pass
    marker = record['marker']
    fd = os.open(record['transcript'], os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as f:
        info = os.fstat(f.fileno())
        if [info.st_dev, info.st_ino] != record['transcript_pin']:
            raise ValueError('Opened transcript incarnation changed')
        if info.st_size < record['transcript_offset']:
            raise ValueError('Transcript truncated')
        f.seek(record['transcript_offset'])
        data = f.read((8 << 20) + 1)
    if len(data) > 8 << 20:
        raise ValueError('Fresh transcript window exceeds bound')
    matches = []
    for line in data.splitlines():
        try: row = json.loads(line)
        except ValueError: continue
        p = row.get('payload', {})
        if row.get('type') == 'response_item' and p.get('type') == 'message' and p.get('role') == 'assistant':
            text = d.text_blocks(p.get('content'))[0]
            if marker in text: matches.append(text)
    recheck()
    rendered = ''.join(chunks)
    if len(matches) != 1 or marker not in rendered or matches[0] not in rendered:
        raise ValueError('Fresh unique assistant marker not proven in both sources')
    print(json.dumps(dict(status='fresh_output_correlated', pane=record['pane'], pid=record['pid'],
                         session=record['session'], process_start=record['process_start'],
                         transcript_pin=record['transcript_pin'], first_log_id=record['log_offset'],
                         native_start=record['native_start'],
                         last_log_id=last_log_id, marker=marker,
                         limitation='Observation only; no durable frontend binding or delivery authorization created')))
