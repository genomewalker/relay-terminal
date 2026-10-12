#!/usr/bin/env python3
"""Disposable native-peer protocol fixture. Never reads the user's registry."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import threading
import uuid

name, home, cwd = sys.argv[1:4]
home = Path(home).resolve()
if not str(home).startswith('/tmp/') and not str(home).startswith('/private/tmp/'):
    raise SystemExit('fixture requires a disposable /tmp home')
registry = home / '.claude/sessions'
registry.mkdir(parents=True, mode=0o700)
os.chmod(registry, 0o700)
path = str(home / 'worker.sock')
secret = secrets.token_hex(16)
pid = os.getpid()
start = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                                env={**os.environ, 'TZ': 'UTC', 'LC_ALL': 'C'}, text=True).strip()
record = dict(pid=pid, name='codex-' + name, sessionId=name, cwd=cwd, procStart=start, messagingSocketPath=path)
listener = socket.socket(socket.AF_UNIX)
listener.bind(path)
listener.listen()
os.chmod(path, 0o600)
for file, value in [(registry / f'{pid}.json', record),
                    (registry / f'{pid}.{hashlib.sha256(path.encode()).hexdigest()}.key', {'peerToken': secret})]:
    file.write_text(json.dumps(value))
    file.chmod(0o600)
output_lock = threading.Lock()


def emit(value):
    with output_lock:
        print(json.dumps(value), flush=True)


def peers():
    result = []
    for file in registry.glob('*.json'):
        try:
            value = json.loads(file.read_text())
            if value.get('pid') == pid:
                continue
            os.kill(value['pid'], 0)
            if not Path(value['messagingSocketPath']).exists():
                continue
            result.append(value)
        except (OSError, KeyError, ValueError):
            continue
    return result


def accept():
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(5)
            stream = connection.makefile('rb')
            try:
                auth = json.loads(stream.readline(65537))
                if auth.get('type') != 'auth' or not secrets.compare_digest(auth.get('token', ''), secret):
                    continue
                message = json.loads(stream.readline(65537))
                content = message['message']['content']
                envelope = re.fullmatch(r'<cross-session-message[^>]*from-name="([^"]+)"[^>]*>\n(.*)\n</cross-session-message>', content, re.DOTALL)
                if envelope:
                    emit({'sender': envelope[1], 'content': envelope[2]})
            except (OSError, ValueError, KeyError):
                continue


threading.Thread(target=accept, daemon=True).start()
emit({'ready': True})
try:
    for line in sys.stdin:
        request = json.loads(line)
        response = {'id': request['id']}
        try:
            available = peers()
            if request['op'] == 'list':
                response['result'] = available
            elif request['op'] == 'send':
                target = next(p for p in available if p['name'] == request['recipient'])
                target_path = target['messagingSocketPath']
                key = registry / f"{target['pid']}.{hashlib.sha256(target_path.encode()).hexdigest()}.key"
                token = json.loads(key.read_text())['peerToken']
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(5)
                    client.connect(target_path)
                    frames = [{'type': 'auth', 'token': token},
                              {'type': 'user', 'msg_id': uuid.uuid4().hex, 'from': 'uds:' + path,
                               'message': {'role': 'user', 'content': request['content']}}]
                    client.sendall(b''.join((json.dumps(f) + '\n').encode() for f in frames))
                response['result'] = 'sent'
            else:
                raise ValueError('unknown operation')
        except (OSError, ValueError, KeyError, StopIteration) as error:
            response['error'] = str(error) or 'peer unavailable'
        emit(response)
finally:
    listener.close()
