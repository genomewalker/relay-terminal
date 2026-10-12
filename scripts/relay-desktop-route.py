"""Relay-owned direct desktop route. Explicit config; no implicit task resume.

listen: bounded SSH reconnection and native replies -> signed App Server.
send: one bounded stdin message through the live route. Never retries sends.
"""
import argparse
import asyncio
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import plistlib
import shlex
import signal
import stat
import sys
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('ingress', ROOT / 'codex-desktop-deliver.py')
ingress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ingress)


class RebindRequired(RuntimeError):
    pass


class IdentityRecovered(RuntimeError):
    pass


def reconnect_delay(attempt):
    return min(2 ** min(max(attempt, 0), 5), 30)


def route_key(c):
    # Names and PIDs are display/incarnation data, never task identity.
    binding = json.dumps([c['thread'], c['host'], c['remoteSession']], separators=(',', ':'))
    return hashlib.sha256(binding.encode()).hexdigest()[:32]


def saved_route_for(c, root):
    files = [path for path in root.glob('*.json') if path.name != 'connections.json']
    if len(files) > 64:
        raise ValueError('too many saved routes')
    matches = []
    for path in files:
        item = read_private(path)
        validate_config(item)
        if (item['thread'] == c['thread'] and item['host'] == c['host']
                and item['remoteSession'] == c['remoteSession']):
            matches.append(path)
    if len(matches) > 1:
        raise ValueError('ambiguous saved route for this task and session')
    return matches[0] if matches else None


def connection_registry(root):
    """Metadata only: a stable route name and its explicit desktop task lineage."""
    path = root / 'connections.json'
    if not path.exists():
        return []
    rows = read_private(path, limit=65536)
    identifier = r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}'
    if (not isinstance(rows, list) or len(rows) > 64
            or any(not isinstance(row, dict)
                   or any(not isinstance(row.get(key), str) or not re.fullmatch(identifier, row[key])
                          for key in ('replyName', 'host', 'remoteSession', 'currentTask'))
                   or not isinstance(row.get('tasks'), list) or not 1 <= len(row['tasks']) <= 32
                   or any(not isinstance(task, str) or not re.fullmatch(identifier, task)
                          for task in row['tasks'])
                   or row['currentTask'] != row['tasks'][-1]
                   for row in rows)):
        raise ValueError('invalid Relay connection registry')
    return rows


def record_connection(root, c, previous_thread=None):
    import fcntl
    lock_path = root / '.connections.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('unsafe connection registry lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = connection_registry(root)
        matches = [row for row in rows if row['replyName'] == c['localName']]
        if len(matches) > 1:
            raise ValueError('duplicate Relay connection identity')
        if matches:
            row = matches[0]
            if row.get('host') != c['host'] or row.get('remoteSession') != c['remoteSession']:
                raise ValueError('saved connection changed endpoints')
            if previous_thread is not None and row.get('currentTask') != previous_thread:
                raise ValueError('connection lineage changed')
        else:
            row = dict(replyName=c['localName'], host=c['host'],
                       remoteSession=c['remoteSession'], tasks=[])
            rows.append(row)
        if matches and previous_thread is None and row.get('currentTask') == c['thread']:
            return
        if previous_thread is not None and not matches:
            row['tasks'].append(previous_thread)
        if not row['tasks'] or row['tasks'][-1] != c['thread']:
            if len(row['tasks']) >= 32:
                raise ValueError('connection lineage is full')
            row['tasks'].append(c['thread'])
        row['currentTask'] = c['thread']
        row['updatedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
        if len(rows) > 64:
            raise ValueError('connection registry is full')
        write(root / 'connections.json', rows)


def sync_connections(home):
    root = home / '.local/share/relay/desktop-routing'
    files = [path for path in root.glob('*.json') if path.name != 'connections.json']
    if len(files) > 64:
        raise ValueError('too many saved routes')
    for path in files:
        c = read_private(path)
        validate_config(c)
        service_for_config(path, home)
        record_connection(root, c)
    return connection_registry(root)


def service_for_config(path, home):
    agents = home / 'Library/LaunchAgents'
    root = home / '.local/share/relay/desktop-routing'
    matches = []
    services = list(agents.glob('dev.vaklab.relay-desktop-*.plist'))
    if len(services) > 64:
        raise ValueError('too many saved route services')
    for service in services:
        info = service.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            continue
        try:
            data = plistlib.loads(service.read_bytes())
        except (ValueError, OSError):
            continue
        label = data.get('Label')
        args = data.get('ProgramArguments')
        if (isinstance(label, str) and service.name == label + '.plist'
                and isinstance(args, list) and len(args) == 5
                and args == [str(root/'venv/bin/python'), str(root/'relay-desktop-route.py'),
                             'listen', '--config', str(path)]):
            matches.append((label, service))
    if len(matches) != 1:
        raise ValueError('saved route service is missing or ambiguous')
    return matches[0]


def handoff(path, new_thread, home=None):
    home = home or Path.home()
    root = home / '.local/share/relay/desktop-routing'
    if path.parent != root or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}', new_thread):
        raise ValueError('invalid route handoff')
    old = read_private(path)
    validate_config(old)
    if old['thread'] == new_thread:
        raise ValueError('choose a different desktop task')
    for other in root.glob('*.json'):
        if other == path or other.name == 'connections.json':
            continue
        candidate = read_private(other)
        if (candidate['thread'] == new_thread and candidate['host'] == old['host']
                and candidate['remoteSession'] == old['remoteSession']):
            raise ValueError('new task already has a route to this session')
    updated = dict(old, thread=new_thread)
    write(path, updated)
    try:
        record_connection(root, updated, previous_thread=old['thread'])
    except BaseException:
        write(path, old)
        raise
    return updated


def remember(c, home=None, rebind=False):
    """Save one explicitly selected pair; never overwrite a changed binding."""
    validate_config(c)
    home = home or Path.home()
    root = home / '.local/share/relay/desktop-routing'
    if not root.is_dir() or root.is_symlink():
        raise ValueError('Relay desktop routing runtime must be installed first')
    key = route_key(c)
    config = saved_route_for(c, root) or root / (key + '.json')
    saved = dict(c, localName=read_private(config)['localName'] if config.exists() else 'relay-' + key)
    needs_write = not config.exists()
    if rebind and needs_write:
        raise ValueError('no saved route for explicit rebind')
    if not needs_write:
        previous = read_private(config)
        if previous != saved:
            changed = {field for field in previous.keys() | saved.keys()
                       if previous.get(field) != saved.get(field)}
            if not rebind or not changed <= {'remoteName', 'remotePID', 'remoteStart'}:
                raise ValueError('saved binding changed; explicit rebind required')
            needs_write = True
    agents = home / 'Library/LaunchAgents'
    agents.mkdir(parents=True, exist_ok=True)
    if config.exists() and config.name != key + '.json':
        label, service = service_for_config(config, home)
    else:
        label = 'dev.vaklab.relay-desktop-' + key
        service = agents / (label + '.plist')
    definition = dict(Label=label, ProgramArguments=[str(root/'venv/bin/python'),
        str(root/'relay-desktop-route.py'), 'listen', '--config', str(config)],
        RunAtLoad=True, KeepAlive=False, EnvironmentVariables=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin'))
    encoded = plistlib.dumps(definition)
    if service.exists():
        info = service.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('unsafe saved launch service')
        if service.read_bytes() != encoded:
            raise ValueError('launch service changed; repair explicitly')
    else:
        fd = os.open(service, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(encoded)
    if needs_write:
        write(config, saved)
    record_connection(root, saved)
    return dict(config=str(config), service=str(service), label=label, replyName=saved['localName'])


def validate_config(c):
    if not isinstance(c, dict):
        raise ValueError('route configuration must be an object')
    for key in ('host', 'localName', 'remoteSession', 'thread', 'remoteName'):
        value = c.get(key)
        if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}', value):
            raise ValueError('invalid route identifier: '+key)
    if type(c.get('remotePID')) is not int or c['remotePID'] <= 0:
        raise ValueError('invalid remote PID')
    remote_start = c.get('remoteStart')
    if (not isinstance(remote_start, str) or not remote_start or len(remote_start.encode()) > 128
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in remote_start)
            or (c['host'] != 'laptop' and not re.fullmatch(r'[0-9]{1,24}', remote_start))):
        raise ValueError('invalid remote incarnation')
    if not isinstance(c.get('socket'), str) or not Path(c['socket']).is_absolute():
        raise ValueError('desktop socket must be absolute')


def validate_live_route(c, state, now):
    bindings = dict(host=c['host'], localName=c['localName'], localSession=c['thread'],
                    remoteSession=c['remoteSession'], remotePID=c['remotePID'],
                    remoteStart=c['remoteStart'])
    if not isinstance(state, dict) or any(state.get(k) != v for k, v in bindings.items()):
        raise ValueError('route identity changed; message not sent')
    heartbeat = state.get('heartbeatEpoch')
    if (state.get('state') != 'online' or type(heartbeat) not in (int, float)
            or not 0 <= now-heartbeat <= 25):
        raise ValueError('route offline or stale; message not sent')
    mailbox = state.get('mailbox')
    if (not isinstance(mailbox, dict) or type(mailbox.get('pid')) is not int
            or mailbox['pid'] <= 0 or not isinstance(mailbox.get('start'), str)
            or not mailbox['start'] or len(mailbox['start']) > 64
            or (c['host'] != 'laptop' and not re.fullmatch(r'[0-9]{1,24}', mailbox['start']))):
        raise ValueError('invalid reply mailbox; message not sent')
    return mailbox


def adopt_same_session(c, path, event):
    if (event.get('session') != c['remoteSession'] or type(event.get('pid')) is not int
            or event['pid'] <= 0 or not isinstance(event.get('start'), str)
            or not event['start'] or len(event['start']) > 64
            or (c['host'] != 'laptop' and not re.fullmatch(r'[0-9]{1,24}', event['start']))
            or not isinstance(event.get('name'), str)
            or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}', event['name'])):
        raise RebindRequired('Remote replacement identity was invalid')
    if read_private(path) != c:
        raise RebindRequired('Saved route changed while reconnecting')
    updated = dict(c, remotePID=event['pid'], remoteStart=event['start'], remoteName=event['name'])
    validate_config(updated)
    if updated != c:
        write(path, updated)
        c.update(updated)
    return updated


def read_private(path, limit=16384):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > limit:
        raise ValueError('configuration/status must be private and bounded')
    return json.loads(path.read_text())


def write(path, value):
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.route-')
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def receipt_file(config):
    directory = config.parent / 'receipts'
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('unsafe receipt directory')
    return directory / (config.stem + '.json')


def update_read_receipt(config, message_id, status, *, create=False):
    """Bounded evidence with permanent ID reservations; never replay a send."""
    import fcntl
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,110}', message_id):
        raise ValueError('invalid message id')
    path = receipt_file(config)
    lock_path = path.with_suffix('.lock')
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('unsafe receipt lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = read_private(path, limit=65536) if path.exists() else []
        if not isinstance(rows, list) or len(rows) > 256:
            raise ValueError('invalid receipt ledger')
        if not all(isinstance(row, dict) and isinstance(row.get('id'), str) for row in rows):
            raise ValueError('invalid receipt row')
        index = next((i for i, row in enumerate(rows) if isinstance(row, dict) and row.get('id') == message_id), None)
        if create:
            if index is not None:
                raise ValueError('message ID already used; do not retry')
            # History may be trimmed; reservations must survive that trimming.
            # Migrate every retained ID before reserving or evicting any row.
            reservations = path.with_suffix('.ids')
            reservations.mkdir(mode=0o700, exist_ok=True)
            info = reservations.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('unsafe message reservation directory')
            for reserved_id in [row.get('id') for row in rows] + [message_id]:
                if not isinstance(reserved_id, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,110}', reserved_id):
                    raise ValueError('invalid receipt ID')
                reservation = reservations / ('id-' + reserved_id)
                try:
                    reservation_fd = os.open(reservation, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                except FileExistsError:
                    if reserved_id == message_id:
                        raise ValueError('message ID already used; do not retry')
                    info = reservation.lstat()
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                        raise ValueError('unsafe message reservation')
                    if info.st_size == 0:
                        prior = next(row for row in rows if row['id'] == reserved_id)
                        write(reservation, prior)
                else:
                    try:
                        row = next((row for row in rows if row['id'] == reserved_id),
                                   dict(id=reserved_id, status=status, updatedAt=time.time()))
                        os.write(reservation_fd, json.dumps(row).encode())
                        os.fsync(reservation_fd)
                    finally:
                        os.close(reservation_fd)
            directory_fd = os.open(reservations, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            rows.append(dict(id=message_id, status=status, updatedAt=time.time()))
            rows = rows[-256:]
        else:
            if index is None:
                archived = path.with_suffix('.ids') / ('id-' + message_id)
                if not archived.exists():
                    return False
                # Old versions stored an empty reservation. Its existence proves
                # the ID was dispatched; an authenticated peer can still ack it.
                info = archived.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise ValueError('unsafe archived receipt')
                prior = read_private(archived) if info.st_size else dict(id=message_id, status='unknown', updatedAt=time.time())
                rows.append(prior)
                rows = rows[-256:]
                index = len(rows) - 1
            if rows[index].get('status') == 'read_acknowledged' and status != 'read_acknowledged':
                return True
            rows[index] = dict(id=message_id, status=status, updatedAt=time.time())
        archives = path.with_suffix('.ids')
        if archives.is_dir():
            # Only the changed receipt needs syncing; existing IDs are migrated
            # once above. Avoid hundreds of fsyncs for every incoming message.
            row = next(row for row in rows if row['id'] == message_id)
            write(archives / ('id-' + message_id), row)
        write(path, rows)
        return True


def read_acknowledgment(content):
    if not isinstance(content, str):
        return None
    body = content.strip()
    if body.startswith('<cross-session-message '):
        opening = body.find('>')
        closing = body.rfind('</cross-session-message>')
        if opening < 0 or closing < opening or closing + len('</cross-session-message>') != len(body):
            return None
        body = body[opening + 1:closing].strip()
    match = re.fullmatch(r'Relay-Read-Receipt: ([A-Za-z0-9_.-]{1,110})', body)
    return match.group(1) if match else None


def command(c, mode, mailbox=None):
    args = ['python3', '-u', '-c', (ROOT / 'relay-desktop-remote.py').read_text(), mode,
            str(c['remotePID']), c['remoteSession'], c['remoteStart'], c['localName']]
    if mailbox:
        args += [str(mailbox['pid']), mailbox['start']]
    # All host execution uses Relay's authenticated persistent node channel.
    # No direct SSH fallback: an unavailable Relay connection is observable.
    return [sys.executable, str(ROOT / 'relay-host-process.py'), c['host'], mode,
            *(['--receipt-checkpoints'] if mode == 'listen' else []), *args]



async def run(c, path, mode, delivery=None):
    validate_config(c)
    await ingress.verify_loaded_task(c['socket'], c['thread'])
    status_dir = Path.home() / '.local/state/relay/peer-network'
    status_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = status_dir.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('unsafe status directory')
    status_path = status_dir / (c['localName']+'.json')
    if mode == 'send':
        state = read_private(status_path)
        mailbox = validate_live_route(c, state, time.time())
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            raise ValueError('message too large')
        message = json.loads(raw)
        if not isinstance(message, dict) or not isinstance(message.get('content'), str) or not message['content'].strip():
            raise ValueError('message content required')
        message_id = message.get('id')
        # Caller content cannot choose an attestation. Unknown stays unasserted.
        message.pop('permissionClass', None)
        permission_class = await ingress.sender_permission_class(c['socket'], c['thread'])
        if permission_class is not None:
            message['permissionClass'] = permission_class
        if not isinstance(message_id, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,110}', message_id):
            raise ValueError('invalid message id')
        if message.get('readReceipt', True) is not False:
            request = ('\n\n[Relay read receipt: after reading, send a separate message to '
                       + c['localName'] + ' containing exactly "Relay-Read-Receipt: '
                       + message_id + '". This confirms reading, not just delivery.]')
            message['content'] += request
        raw = json.dumps(message).encode()
        if len(raw) > 65536:
            raise ValueError('message too large with receipt request')
        update_read_receipt(path, message_id, 'pending', create=True)
        proc = None
        try:
            arguments = command(c, 'send', mailbox)
            if delivery is not None:
                delivery['dispatched'] = True
            proc = await asyncio.create_subprocess_exec(*arguments,
                        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
            output, _ = await asyncio.wait_for(proc.communicate(raw), 20)
        except BaseException:
            if proc is not None and proc.returncode is None:
                proc.kill()
                await proc.wait()
            update_read_receipt(path, message_id, 'unknown')
            raise
        response = output.decode().strip() or '{"receipt":"unknown"}'
        try:
            value = json.loads(response)
            status = value.get('receipt') if value.get('receipt') in ('written_to_socket', 'not_sent') else 'unknown'
        except (ValueError, AttributeError):
            status = 'unknown'
        update_read_receipt(path, message_id, status)
        print(response)
        if proc.returncode:
            raise SystemExit(1)
        return
    # An advisory lock prevents two supervisors for the same desktop task/route.
    import fcntl
    with open(str(path)+'.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = dict(schema=1, pid=os.getpid(), host=c['host'], localName=c['localName'],
                     localSession=c['thread'], remoteName=c['remoteName'],
                     remotePID=c['remotePID'], remoteStart=c['remoteStart'],
                     remoteSession=c['remoteSession'], rttMillis=-1, attempt=0, state='connecting')
        def publish():
            state['updatedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
            write(status_path, state)
        seen = set()
        try:
            attempt = 0
            while True:
                recovered = False
                state.update(state='connecting', attempt=attempt)
                publish()
                proc = await asyncio.create_subprocess_exec(*command(c, 'listen'),
                        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, limit=131072)
                try:
                    while True:
                        line = await asyncio.wait_for(proc.stdout.readline(), 30)
                        if not line:
                            raise ConnectionError('Relay host adapter ended; check saved listener job and permission status')
                        if len(line) > 131072:
                            raise ValueError('oversized route frame')
                        event = json.loads(line)
                        if event.get('type') == 'transport_status':
                            state.update(state=event['state'], error=event.get('message'))
                            state.pop('mailbox', None)
                            publish()
                            continue
                        event_offset = None
                        if event.get('type') == 'host_event':
                            event_offset = event.get('offset')
                            if type(event_offset) is not int or event_offset < 0 or not isinstance(event.get('event'), dict):
                                raise ValueError('invalid host event envelope')
                            event = event['event']
                        async def acknowledge_event():
                            if event_offset is not None:
                                proc.stdin.write((json.dumps(dict(ack_offset=event_offset))+'\n').encode())
                                await proc.stdin.drain()
                        if event['type'] == 'identity_changed':
                            raise RebindRequired('Remote identity changed; explicitly rebind this saved route')
                        if event['type'] == 'identity_missing':
                            raise ConnectionError('Remote session is absent; waiting for the same session to return')
                        if event['type'] == 'identity_replacement':
                            adopt_same_session(c, path, event)
                            state.update(remoteName=c['remoteName'], remotePID=c['remotePID'],
                                         remoteStart=c['remoteStart'], state='connecting', error=None)
                            state.pop('mailbox', None)
                            state.pop('heartbeatEpoch', None)
                            publish()
                            raise IdentityRecovered()
                        if event['type'] in ('ready', 'heartbeat'):
                            await ingress.verify_loaded_task(c['socket'], c['thread'])
                        if event['type'] == 'ready':
                            state.update(mailbox=event, state='online', error=None)
                            attempt = 0
                        if event['type'] in ('ready', 'heartbeat'):
                            state['heartbeatEpoch'] = time.time()
                        elif event['type'] == 'message':
                            if event['id'] in seen:
                                await acknowledge_event()
                                continue
                            if len(seen) >= 4096:
                                raise RuntimeError('message budget reached; explicit restart required')
                            incoming_config = path.with_name(path.stem + '-incoming' + path.suffix)
                            try:
                                update_read_receipt(incoming_config, event['id'], 'pending', create=True)
                            except ValueError as error:
                                if str(error) == 'message ID already used; do not retry':
                                    await acknowledge_event()
                                    continue
                                raise
                            seen.add(event['id'])
                            acknowledged = read_acknowledgment(event.get('content'))
                            if acknowledged and update_read_receipt(path, acknowledged, 'read_acknowledged'):
                                state.update(lastReadMessageId=acknowledged,
                                             lastReadReceipt='read_acknowledged')
                            event['sender'] = c['host']+'--'+event['sender']
                            result = await ingress.deliver(c['socket'], c['thread'], event)
                            update_read_receipt(incoming_config, event['id'],
                                                'admitted' if result['receipt'] == 'admitted' else 'unknown')
                            state.update(lastMessageId=event['id'], lastReceipt=result['receipt'])
                            if result['receipt'] != 'admitted':
                                state['error'] = 'Desktop admission failed; no replay. '+result.get('error','')
                        publish()
                        await acknowledge_event()
                except IdentityRecovered:
                    recovered = True
                except RebindRequired as error:
                    state.update(state='needs_attention', error=str(error), rebindRequired=True)
                    state.pop('mailbox', None)
                    publish()
                    return
                except (OSError, ValueError, RuntimeError, asyncio.TimeoutError) as error:
                    state.update(state='offline', error=str(error))
                    state.pop('mailbox', None)
                    publish()
                finally:
                    if proc.returncode is None:
                        # A failed pipe detaches from its durable host listener;
                        # explicit disconnect still terminates only that listener.
                        if state.get('state') in ('offline', 'permission_required', 'transport_unavailable'):
                            proc.send_signal(signal.SIGUSR1)
                        else:
                            proc.terminate()
                        try:
                            await asyncio.wait_for(proc.wait(), 5)
                        except asyncio.TimeoutError:
                            proc.kill()
                            await proc.wait()
                if len(seen) >= 4096:
                    break
                if recovered:
                    attempt = 0
                    continue
                await asyncio.sleep(reconnect_delay(attempt))
                attempt += 1
        finally:
            if state.get('state') != 'needs_attention':
                state['state'] = 'stopped'
            publish()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['listen', 'send', 'remember', 'handoff', 'tasks', 'connections', 'work-register', 'task-check', 'task-prepare'])
    parser.add_argument('--config', type=Path)
    parser.add_argument('--socket')
    parser.add_argument('--work-app-pid', type=int)
    parser.add_argument('--work-app-start')
    parser.add_argument('--thread', help='Explicit destination desktop task for handoff')
    parser.add_argument('--connect', action='store_true', help='Explicitly enable the selected remembered route')
    parser.add_argument('--rebind', action='store_true', help='Replace only the selected saved route incarnation')
    parser.add_argument('--details', action='store_true', help='List names and activity of loaded desktop tasks')
    parser.add_argument('--sync', action='store_true', help='Import verified saved routes into the connection registry')
    args = parser.parse_args()
    if args.mode == 'work-register':
        if not args.thread or not args.work_app_pid or not args.work_app_start:
            parser.error('exact thread and Work app incarnation required')
        print(json.dumps(await ingress.register_work_task(
            args.thread, args.work_app_pid, args.work_app_start)))
        return
    if args.mode in ('task-check', 'task-prepare'):
        if not args.socket or not args.thread:
            parser.error('--socket and exact --thread are required')
        selected = await (ingress.prepare_loaded_task(args.socket, args.thread)
                          if args.mode == 'task-prepare'
                          else ingress.inspect_loaded_task(args.socket, args.thread))
        print(json.dumps(dict(id=selected['id'], transport=selected['transport'])))
        return
    if args.mode == 'connections':
        print(json.dumps(sync_connections(Path.home()) if args.sync else
                         connection_registry(Path.home()/'.local/share/relay/desktop-routing')))
        return
    if args.mode == 'tasks':
        if not args.socket:
            parser.error('--socket is required')
        print(json.dumps(await (ingress.loaded_task_details(args.socket) if args.details
                                else ingress.loaded_tasks(args.socket))))
        return
    if not args.config:
        parser.error('--config is required')
    if args.mode == 'handoff':
        if not args.thread:
            parser.error('--thread is required')
        old = read_private(args.config)
        validate_config(old)
        await ingress.prepare_loaded_task(old['socket'], args.thread)
        label, service = service_for_config(args.config, Path.home())
        target = 'gui/%d/%s' % (os.getuid(), label)
        subprocess.run(['launchctl', 'disable', target], check=True)
        if subprocess.run(['launchctl', 'print', target], capture_output=True).returncode == 0:
            subprocess.run(['launchctl', 'bootout', target], check=True)
        updated = handoff(args.config, args.thread)
        subprocess.run(['launchctl', 'enable', target], check=True)
        subprocess.run(['launchctl', 'bootstrap', 'gui/%d' % os.getuid(), str(service)], check=True)
        print(json.dumps(dict(replyName=updated['localName'], task=updated['thread'])))
        return
    if args.mode == 'remember':
        selected = read_private(args.config)
        validate_config(selected)
        await ingress.prepare_loaded_task(selected['socket'], selected['thread'])
        if args.rebind:
            if not args.connect:
                parser.error('--rebind requires --connect')
            validate_config(selected)
            root = Path.home() / '.local/share/relay/desktop-routing'
            existing = saved_route_for(selected, root)
            if existing is None:
                raise ValueError('no saved route for this task, host and session')
            old = read_private(existing)
            changed = {field for field in old.keys() | selected.keys()
                       if old.get(field) != selected.get(field) and field != 'localName'}
            if not changed or not changed <= {'remoteName', 'remotePID', 'remoteStart'}:
                raise ValueError('only the selected remote incarnation may be rebound')
            label, _ = service_for_config(existing, Path.home())
            target = 'gui/%d/%s' % (os.getuid(), label)
            subprocess.run(['launchctl', 'disable', target], check=True)
            if subprocess.run(['launchctl', 'print', target], capture_output=True).returncode == 0:
                subprocess.run(['launchctl', 'bootout', target], check=True)
        result = remember(selected, rebind=args.rebind)
        target = 'gui/%d/%s' % (os.getuid(), result['label'])
        if args.connect:
            subprocess.run(['launchctl', 'enable', target], check=True)
        # An existing explicitly disabled route stays disabled. Remembering a
        # pair twice is not permission to override a previous disconnect.
        loaded = subprocess.run(['launchctl', 'print', target], capture_output=True).returncode == 0
        if not loaded:
            subprocess.run(['launchctl', 'bootstrap', 'gui/%d' % os.getuid(), result['service']], check=True)
        if args.connect:
            subprocess.run(['launchctl', 'kickstart', target], check=True)
        print(json.dumps(result))
        return
    task = asyncio.current_task()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, task.cancel)
    if args.mode == 'send':
        delivery = dict(dispatched=False)
        try:
            await run(read_private(args.config), args.config, args.mode, delivery)
        except Exception:
            print(json.dumps(dict(receipt='unknown' if delivery['dispatched'] else 'not_sent',
                                  retrySafe=False)))
            raise SystemExit(1)
    else:
        await run(read_private(args.config), args.config, args.mode)


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except asyncio.CancelledError:
        pass
