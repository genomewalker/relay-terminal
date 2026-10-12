"""Read subscription observations only. Never launch, resume, or submit to an agent."""
import base64
import hashlib
import json
import math
import urllib.request
import os
from pathlib import Path
import socket
import stat
import struct
import sys
import time
import subprocess
import tempfile
from datetime import datetime, timezone

LIMIT = 65536

def reset_timestamp(value):
    """Parse timezone-bearing API resets on supported older remote Python hosts."""
    if not isinstance(value, str) or len(value) > 80: raise ValueError('invalid reset')
    if value.endswith('Z'): value = value[:-1] + '+0000'
    if len(value) >= 6 and value[-6] in '+-' and value[-3] == ':':
        value = value[:-3] + value[-2:]
    for pattern in ('%Y-%m-%dT%H:%M:%S.%f%z', '%Y-%m-%dT%H:%M:%S%z'):
        try: return datetime.strptime(value, pattern).timestamp()
        except ValueError: pass
    raise ValueError('invalid reset')

def account_scope(provider):
    """Only a digest of provider account identifiers leaves the host. Never tokens/email."""
    try:
        home = Path.home()
        if provider == 'codex':
            root = Path(os.environ.get('CODEX_HOME', str(home / '.codex')))
            value = private_file(root / 'auth.json')
            ident = value.get('tokens', {}).get('account_id')
            if not isinstance(ident, str) or not ident or len(ident) > 256: return None
            identity = ['codex', ident]
        else:
            configured = os.environ.get('CLAUDE_CONFIG_DIR')
            path = Path(configured) / '.claude.json' if configured else home / '.claude.json'
            value = private_file(path, maximum=4 << 20).get('oauthAccount', {})
            ident, org = value.get('accountUuid'), value.get('organizationUuid')
            if not all(isinstance(v, str) and 0 < len(v) <= 256 for v in (ident, org)): return None
            identity = ['claude', ident, org]
        return hashlib.sha256(json.dumps(identity, separators=(',', ':')).encode()).hexdigest()
    except (OSError, ValueError, AttributeError, TypeError):
        return None

def private_file(path, maximum=LIMIT):
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > maximum:
            raise ValueError('private quota observation unavailable')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            return json.loads(stream.read(maximum + 1))
    finally:
        os.close(fd)

class ReadSocket:
    def __init__(self, path):
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            parent = os.stat(path.parent)
            if info.st_uid != os.getuid() or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
                raise ValueError('unsafe control socket link')
            path = path.resolve()
            info = os.lstat(path)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError('private control socket unavailable')
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(4)
        self.socket.connect(str(path))
        after = os.stat(path)
        if (info.st_dev, info.st_ino) != (after.st_dev, after.st_ino):
            self.socket.close()
            raise ValueError('control socket changed')
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        response = bytearray()
        while not response.endswith(b'\r\n\r\n') and len(response) < 8192:
            response.extend(self.read(1))
        expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        headers = response.decode().split('\r\n')
        fields = {row.split(':', 1)[0].lower(): row.split(':', 1)[1].strip() for row in headers[1:] if ':' in row}
        if ' 101 ' not in headers[0] or fields.get('sec-websocket-accept', '') != expected:
            self.socket.close()
            raise ValueError('unsupported control protocol')

    def read(self, size):
        result = bytearray()
        while len(result) < size:
            value = self.socket.recv(size - len(result))
            if not value:
                raise ConnectionError('control socket closed')
            result.extend(value)
        return bytes(result)

    def send(self, value, opcode=1):
        data = json.dumps(value).encode() if opcode == 1 else value
        length = len(data)
        header = bytes([0x80 | opcode, 0x80 | length]) if length < 126 else bytes([0x80 | opcode, 0x80 | 126]) + struct.pack('!H', length)
        mask = os.urandom(4)
        self.socket.sendall(header + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(data)))

    def rpc(self, ident, method, params):
        self.send(dict(id=ident, method=method, params=params))
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            first, second = self.read(2)
            length = second & 127
            if length == 126: length = struct.unpack('!H', self.read(2))[0]
            elif length == 127: length = struct.unpack('!Q', self.read(8))[0]
            if length > LIMIT or second & 128 or not first & 128:
                raise ValueError('unsupported quota frame')
            payload = self.read(length)
            opcode = first & 15
            if opcode == 9:
                self.send(payload, 10)
                continue
            if opcode != 1: raise ValueError('control socket unavailable')
            reply = json.loads(payload)
            if reply.get('id') == ident:
                if 'error' in reply: raise ValueError('quota unavailable')
                return reply.get('result', {})
        raise TimeoutError('quota response expired')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def claude_account_usage():
    """Read account usage with existing login; no inference, login, or token refresh."""
    if sys.platform == 'darwin':
        result = subprocess.run(['/usr/bin/security', 'find-generic-password',
                                 '-s', 'Claude Code-credentials', '-w'],
                                capture_output=True, timeout=4)
        if result.returncode or len(result.stdout) > LIMIT: return None
        credentials = json.loads(result.stdout)
    else:
        directory = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')))
        credentials = private_file(directory / '.credentials.json')
    oauth = credentials.get('claudeAiOauth', {})
    token = oauth.get('accessToken')
    if not isinstance(token, str) or not token or len(token) > 16384: return None
    if 'user:profile' not in oauth.get('scopes', []): return None
    request = urllib.request.Request('https://api.anthropic.com/api/oauth/usage',
        headers={'Authorization': 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20',
                 'User-Agent': 'Relay/0.5.2'}, method='GET')
    with urllib.request.build_opener(NoRedirect).open(request, timeout=5) as response:
        raw = response.read(LIMIT + 1)
    if len(raw) > LIMIT: return None
    value = json.loads(raw)
    limits = {}
    for key in ('five_hour', 'seven_day', 'seven_day_oauth_apps', 'seven_day_opus',
                'seven_day_sonnet', 'seven_day_cowork', 'seven_day_omelette'):
        window = value.get(key)
        if not isinstance(window, dict): continue
        used = window.get('utilization')
        if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100: continue
        reset = window.get('resets_at')
        timestamp = None
        if isinstance(reset, str):
            timestamp = reset_timestamp(reset)
            if not math.isfinite(timestamp) or not 0 < timestamp < 253402300800: continue
        limits[key] = dict(used_percentage=used, resets_at=timestamp)
    additional = []
    reported = value.get('limits')
    for item in (reported if isinstance(reported, list) else [])[:32]:
        if not isinstance(item, dict) or item.get('kind') in ('session', 'weekly_all'): continue
        used = item.get('percent')
        if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100: continue
        scope = item.get('scope') or {}
        model = scope.get('model') or {} if isinstance(scope, dict) else {}
        label = model.get('display_name') if isinstance(model, dict) else None
        if not isinstance(label, str) or not label.strip() or len(label) > 80: continue
        try:
            reset = reset_timestamp(item['resets_at'])
            if not math.isfinite(reset) or not 0 < reset < 253402300800: continue
        except (KeyError, TypeError, ValueError, AttributeError): continue
        ident = hashlib.sha256(json.dumps(scope, sort_keys=True).encode()).hexdigest()[:16]
        additional.append(dict(id='scoped-' + ident, label=label,
                               used_percentage=used, resets_at=reset,
                               duration_minutes=10080 if item.get('group') == 'weekly' else None))
    if not limits and not additional: return None
    return dict(provider='claude', account_scope=account_scope('claude'),
                observation=dict(session_id='account-usage', rate_limits=limits,
                    plan_type=oauth.get('subscriptionType'), additional_limits=additional,
                    spend=value.get('spend') if isinstance(value.get('spend'), dict) else None,
                    captured_at=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')))

def collect(panes):
    result = []
    home = Path.home()
    directory = home / '.local/share/relay/claude-status'
    try:
        live = claude_account_usage()
        if live: result.append(live)
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError): pass
    try:
        snapshots = sorted(directory.glob('session-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)[:16]
        for path in snapshots:
            try:
                value = private_file(path)
                result.append(dict(provider='claude', account_scope=value.get('account_scope'), observation={k: value[k] for k in ('session_id', 'rate_limits', 'captured_at') if k in value}))
            except (OSError, ValueError): pass
    except OSError: pass
    for pane in panes[:128]:
        if not pane or len(pane) > 110 or any(c not in '0123456789abcdefABCDEF-' for c in pane): continue
        try:
            value = private_file(home / '.local/share/relay/claude-status' / (pane + '.json'))
            if str(value.get('pane_id', '')).lower() != pane.lower(): continue
            result.append(dict(provider='claude', account_scope=value.get('account_scope'), observation={k: value[k] for k in ('session_id', 'rate_limits', 'captured_at') if k in value}))
        except (OSError, ValueError): pass
    path = Path(os.environ.get('CODEX_APP_SERVER_CONTROL_SOCKET', str(home / '.codex/app-server-control/app-server-control.sock')))
    client = None
    try:
        client = ReadSocket(path)
        client.rpc(1, 'initialize', dict(clientInfo=dict(name='relay_quota', version='1')))
        client.send(dict(method='initialized', params={}))
        value = client.rpc(2, 'account/rateLimits/read', {})
        result.append(dict(provider='codex', account_scope=account_scope('codex'), observation={k: value[k] for k in ('rateLimits', 'rateLimitsByLimitId', 'rateLimitResetCredits') if k in value}))
    except (OSError, ValueError, ConnectionError, TimeoutError): pass
    finally:
        if client: client.socket.close()
    for provider in ('codex', 'claude'):
        result.append(dict(provider=provider, account_scope=account_scope(provider), identity_only=True))
    return result

def capture_status(raw):
    value = json.loads(raw)
    ident = value.get('session_id', '')
    if not ident or len(ident) > 110 or any(c not in '0123456789abcdefABCDEF-' for c in ident): return
    limits = {}
    for key in ('five_hour', 'seven_day', 'seven_day_oauth_apps', 'seven_day_opus',
                'seven_day_sonnet', 'seven_day_cowork', 'seven_day_omelette'):
        window = value.get('rate_limits', {}).get(key, {})
        used = window.get('used_percentage')
        reset = window.get('resets_at')
        if type(used) not in (int, float) or not 0 <= used <= 100: continue
        if reset is not None and (type(reset) not in (int, float) or not 0 < reset < 253402300800): continue
        limits[key] = dict(used_percentage=used, resets_at=reset)
    record = dict(session_id=ident, rate_limits=limits, account_scope=account_scope('claude'), captured_at=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
    directory = Path.home() / '.local/share/relay/claude-status'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077: return
    fd, temporary = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / ('session-' + ident + '.json'))
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def statusline(command):
    raw = sys.stdin.buffer.read(LIMIT + 1)
    try:
        if len(raw) <= LIMIT: capture_status(raw)
    except (OSError, ValueError, TypeError, AttributeError): pass
    # Existing user command receives the exact original JSON and retains stdout/stderr.
    return subprocess.run(base64.b64decode(command).decode(), shell=True, input=raw).returncode

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--statusline':
        sys.exit(statusline(sys.argv[2]))
    print(json.dumps(collect(sys.argv[1:])))
