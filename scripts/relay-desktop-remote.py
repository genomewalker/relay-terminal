"""Private SSH worker for one explicitly selected peer (Python 3.6+)."""
import hashlib
import contextlib
import fcntl
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

LIMIT = 65536


class IdentityChanged(ValueError):
    pass


@contextlib.contextmanager
def mailbox_directory(name):
    # Stable address lets a peer resolve the same reply route after SSH recovery.
    # The lock prevents simultaneous workers from unlinking each other's socket.
    root = Path('/tmp') / ('relay-desktop-%d' % os.getuid())
    root.mkdir(mode=0o700, exist_ok=True)
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('unsafe mailbox directory')
    directory = root / hashlib.sha256(name.encode()).hexdigest()[:24]
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('unsafe route directory')
    fd = os.open(str(directory/'lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = directory/'peer.sock'
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('unsafe stale mailbox')
            path.unlink()
        try:
            yield str(directory)
        finally:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def private_json(path):
    info = os.lstat(str(path))
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_size > LIMIT:
        raise ValueError('unsafe registry file')
    return json.loads(path.read_text())


def start(pid):
    if sys.platform == 'darwin':
        env = dict(os.environ, TZ='UTC', LC_ALL='C')
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                                env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, universal_newlines=True)
        value = result.stdout.strip()
        if result.returncode or not value:
            raise FileNotFoundError('process no longer exists')
        return value
    return Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19]


def endpoint(registry, pid, session, incarnation):
    try:
        record = private_json(registry / ('%d.json' % pid))
        if (record['pid'] != pid or record['sessionId'] != session
                or record['procStart'] != incarnation or start(pid) != incarnation):
            raise IdentityChanged('recipient changed; explicit rebinding required')
        info = os.lstat(record['messagingSocketPath'])
    except FileNotFoundError:
        # A vanished process, registry record, or socket cannot be restored by
        # retrying SSH. Tell the local supervisor to require an exact rebind.
        raise IdentityChanged('recipient ended or disappeared; explicit rebinding required')
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('unsafe recipient socket')
    return record


def replacement_for_session(registry, session):
    """Find one live, non-proxy incarnation of the already authorized session."""
    matches = []
    files = list(registry.glob('*.json'))
    if len(files) > 4096:
        raise IdentityChanged('registry too large to resolve safely')
    for path in files:
        if not path.stem.isdigit():
            continue
        try:
            record = private_json(path)
            if record.get('sessionId') != session or record.get('relayProxy'):
                continue
            pid = int(path.stem)
            if type(record.get('pid')) is not int or record['pid'] != pid:
                continue
            incarnation = record.get('procStart')
            name = record.get('name')
            if (not isinstance(incarnation, str) or not incarnation or len(incarnation) > 64
                    or not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}', name)):
                continue
            endpoint(registry, pid, session, incarnation)
            matches.append(dict(pid=pid, start=incarnation, name=name))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if len(matches) > 1:
        raise IdentityChanged('multiple live processes claim this session')
    return matches[0] if matches else None


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    mode, pid, session, incarnation, name = sys.argv[1:6]
    pid = int(pid)
    if not re.match(r'^[A-Za-z0-9_.-]{1,100}$', name):
        raise ValueError('invalid reply name')
    registry = Path.home() / '.claude/sessions'
    info = os.lstat(str(registry))
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('registry must be private')
    target = endpoint(registry, pid, session, incarnation)
    if mode == 'send':
        # The supervisor supplies the exact current mailbox identity, not a
        # first-by-name lookup. Never follow an address from message content.
        mailbox_pid, mailbox_start = int(sys.argv[6]), sys.argv[7]
        mailbox = endpoint(registry, mailbox_pid, name, mailbox_start)
        if mailbox['name'] != name:
            raise ValueError('return mailbox changed')
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError('message too large')
        message = json.loads(raw)
        if not isinstance(message.get('content'), str) or not message['content'].strip():
            raise ValueError('content required')
        message_id = message['id']
        if not isinstance(message_id, str) or not re.match(r'^[A-Za-z0-9_.-]{1,110}$', message_id):
            raise ValueError('invalid message id')
        path = target['messagingSocketPath']
        key = private_json(registry / ('%d.%s.key' % (pid, hashlib.sha256(path.encode()).hexdigest())))
        body = message['content'].replace('<cross-session-message', '<\\cross-session-message').replace('</cross-session-message>', '<\\/cross-session-message>')
        address = mailbox['messagingSocketPath']
        permission_class = message.get('permissionClass')
        mode_attribute = (' from-mode="%s"' % permission_class) if permission_class in ('prompting', 'bypass') else ''
        wrapped = '<cross-session-message from="uds:%s" from-session="%s" from-name="%s"%s>\n%s\n</cross-session-message>' % (address, name, name, mode_attribute, body)
        frame = dict(msgV=1, msg_id=message_id, type='user', priority='next',
                     message=dict(role='user', content=wrapped))
        frame['from'] = 'uds:' + address
        payload = (json.dumps(dict(type='auth', token=key['peerToken']))+'\n'+json.dumps(frame)+'\n').encode()
        if len(payload) > LIMIT:
            raise ValueError('wrapped message too large')
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(path)
            client.sendall(payload)
        emit(dict(type='receipt', id=message_id, receipt='written_to_socket'))
        return
    if mode != 'listen':
        raise ValueError('unknown mode')
    own_pid = os.getpid()
    own_start = start(own_pid)
    secret = secrets.token_hex(16)
    created = []
    def stop(*unused):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    with mailbox_directory(name) as tmp:
        path = tmp + '/peer.sock'
        record_path = registry / ('%d.json' % own_pid)
        key_path = registry / ('%d.%s.key' % (own_pid, hashlib.sha256(path.encode()).hexdigest()))
        now = int(time.time()*1000)
        record = dict(pid=own_pid, name=name, sessionId=name, procStart=own_start,
                      cwd=target['cwd'], messagingSocketPath=path, relayProxy=True,
                      status='idle', startedAt=now, updatedAt=now, nameSince=now,
                      statusUpdatedAt=now, version='2.1.239', peerProtocol=1,
                      peerFeatures=['notify_idle'], kind='interactive', entrypoint='cli')
        try:
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                os.chmod(path, 0o600)
                listener.listen(8)
                listener.settimeout(3)
                for dest, value in ((key_path, dict(peerToken=secret, procStart=own_start)), (record_path, record)):
                    fd = os.open(str(dest), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                    created.append(dest)
                    with os.fdopen(fd, 'w') as f:
                        json.dump(value, f)
                emit(dict(type='ready', name=name, pid=own_pid, start=own_start, peer=target['name']))
                last_tick = 0
                while True:
                    current = endpoint(registry, pid, session, incarnation)
                    if current['messagingSocketPath'] != target['messagingSocketPath']:
                        raise IdentityChanged('recipient socket changed')
                    if time.monotonic() - last_tick >= 10:
                        record['updatedAt'] = int(time.time()*1000)
                        fd, temp = tempfile.mkstemp(dir=str(registry), prefix='.relay-heartbeat-')
                        try:
                            with os.fdopen(fd, 'w') as f:
                                json.dump(record, f)
                            os.replace(temp, str(record_path))
                        finally:
                            if os.path.exists(temp):
                                os.unlink(temp)
                        emit(dict(type='heartbeat'))
                        last_tick = time.monotonic()
                    try:
                        conn, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with conn:
                        conn.settimeout(3)
                        try:
                            with conn.makefile('rb') as stream:
                                auth = json.loads(stream.readline(LIMIT+1))
                                if auth.get('type') != 'auth' or not isinstance(auth.get('token'), str) or not hmac.compare_digest(auth['token'], secret):
                                    raise ValueError('authentication rejected')
                                raw = stream.readline(LIMIT+1)
                                if len(raw) > LIMIT:
                                    raise ValueError('message too large')
                                msg = json.loads(raw)
                                if msg.get('type') != 'user' or msg.get('from') != 'uds:'+target['messagingSocketPath']:
                                    raise ValueError('sender mismatch')
                                if not isinstance(msg.get('msg_id'), str) or not re.match(r'^[A-Za-z0-9_.-]{1,110}$', msg['msg_id']):
                                    raise ValueError('invalid message id')
                                if not isinstance(msg.get('message', {}).get('content'), str):
                                    raise ValueError('invalid content')
                                emit(dict(type='message', id=msg['msg_id'], sender=target['name'], content=msg['message']['content']))
                        except (ValueError, KeyError, TypeError, OSError):
                            emit(dict(type='rejected'))
        finally:
            for dest in reversed(created):
                try:
                    dest.unlink()
                except FileNotFoundError:
                    pass


if __name__ == '__main__':
    try:
        main()
    except IdentityChanged:
        if len(sys.argv) > 3 and sys.argv[1] == 'listen':
            try:
                replacement = replacement_for_session(Path.home()/'.claude/sessions', sys.argv[3])
            except IdentityChanged:
                emit(dict(type='identity_changed'))
            else:
                emit(dict(type='identity_replacement', session=sys.argv[3], **replacement) if replacement else
                     dict(type='identity_missing'))
        else:
            emit(dict(type='identity_changed'))
        sys.exit(3)
    except KeyboardInterrupt:
        pass
