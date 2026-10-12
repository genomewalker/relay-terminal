#!/usr/bin/env python3
"""Inspect or recover MCP discovery in an existing, identity-pinned Codex.

Run on the owning host through Relay workspace execution. Never resumes a
thread, submits a turn, starts an agent, or retries a refresh after ambiguity.
Uses only the standard library, including on hosts with Python 3.6.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import struct

LIMIT = 2 ** 20


def process_start(pid):
    return (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()[19]


def private_socket(path):
    parent = os.lstat(os.path.dirname(path))
    info = os.lstat(path)
    if (not stat.S_ISDIR(parent.st_mode) or not stat.S_ISSOCK(info.st_mode)
            or any(x.st_uid != os.getuid() or x.st_mode & 0o077 for x in (parent, info))):
        raise ValueError('control socket is not private and owned by this user')
    return info.st_dev, info.st_ino


def source_owns_listener(pid, path):
    """A home-derived shared endpoint is not proof of the TUI's own runtime."""
    inodes = set()
    for line in Path('/proc/net/unix').read_text().splitlines()[1:]:
        fields = line.split(maxsplit=7)
        if len(fields) == 8 and fields[7] == path and fields[3] == '00010000':
            inodes.add('socket:[' + fields[6] + ']')
    for descriptor in (Path('/proc') / str(pid) / 'fd').iterdir():
        try:
            if os.readlink(str(descriptor)) in inodes:
                return True
        except FileNotFoundError:
            continue
    return False


class Connection:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        try:
            self.connect(path)
        except BaseException:
            self.sock.close()
            raise

    def connect(self, path):
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.sequence = 0
        self.buffer = bytearray()
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        self.sock.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                           'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                           'Sec-WebSocket-Key: ' + key + '\r\n\r\n').encode())
        while b'\r\n\r\n' not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk or len(self.buffer) + len(chunk) > 16384:
                raise ConnectionError('invalid websocket handshake')
            self.buffer.extend(chunk)
        raw, rest = bytes(self.buffer).split(b'\r\n\r\n', 1)
        self.buffer = bytearray(rest)
        lines = raw.decode('ascii').split('\r\n')
        headers = {k.lower(): v.strip() for k, v in (line.split(':', 1) for line in lines[1:] if ':' in line)}
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        if (lines[0].split()[1] != '101' or headers.get('sec-websocket-accept') != accept
                or headers.get('upgrade', '').lower() != 'websocket'):
            raise ConnectionError('websocket upgrade rejected')

    def exact(self, size):
        while len(self.buffer) < size:
            chunk = self.sock.recv(min(65536, size - len(self.buffer)))
            if not chunk:
                raise ConnectionError('control endpoint disconnected')
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:size])
        del self.buffer[:size]
        return result

    def send(self, data, opcode=1):
        mask = secrets.token_bytes(4)
        size = len(data)
        if size > LIMIT:
            raise ValueError('request exceeds limit')
        length = bytes([size | 128]) if size < 126 else (bytes([254]) + struct.pack('!H', size) if size < 65536 else bytes([255]) + struct.pack('!Q', size))
        self.sock.sendall(bytes([128 | opcode]) + length + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def receive(self):
        message = bytearray()
        started = False
        for _ in range(512):
            first, second = self.exact(2)
            if first & 0x70 or second & 128:
                raise ValueError('unsupported websocket frame')
            opcode, size = first & 15, second & 127
            if size == 126:
                size = struct.unpack('!H', self.exact(2))[0]
            elif size == 127:
                size = struct.unpack('!Q', self.exact(8))[0]
            if size > LIMIT or len(message) + size > LIMIT:
                raise ValueError('response exceeds limit')
            data = self.exact(size)
            if opcode in (8, 9, 10):
                if size > 125 or not first & 128:
                    raise ValueError('invalid control frame')
                if opcode == 8:
                    raise ConnectionError('control endpoint closed')
                if opcode == 9:
                    self.send(data, 10)
                continue
            if (not started and opcode != 1) or (started and opcode != 0):
                raise ValueError('unexpected message frame')
            started = True
            message.extend(data)
            if first & 128:
                return json.loads(message.decode())
        raise ValueError('too many websocket frames')

    def rpc(self, method, params):
        self.sequence += 1
        ident = self.sequence
        self.send(json.dumps({'id': ident, 'method': method, 'params': params}).encode())
        for _ in range(256):
            value = self.receive()
            if value.get('id') == ident:
                if 'error' in value:
                    raise RuntimeError('control request rejected: ' + str(value['error'].get('code')))
                return value['result']
        raise ValueError('too many notifications')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--start', required=True)
    parser.add_argument('--thread', required=True)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--cwd', required=True)
    parser.add_argument('--server', default='relayDesktopR')
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--inspect-loaded', action='store_true', help='Read bounded loaded thread identities; never refreshes')
    args = parser.parse_args()
    if args.inspect_loaded and args.refresh:
        parser.error('loaded thread inspection cannot refresh')
    if process_start(args.pid) != args.start:
        raise ValueError('source process identity changed')
    process = Path('/proc') / str(args.pid)
    if process.stat().st_uid != os.getuid() or Path(os.readlink(str(process / 'exe'))).name != 'codex':
        raise ValueError('source is not an owned Codex process')
    environment = dict(field.split('=', 1) for field in (process / 'environ').read_text().split('\0') if '=' in field)
    argv = (process / 'cmdline').read_text().split('\0')
    remotes = [value.split('=', 1)[1] for value in argv if value.startswith('--remote=')]
    remotes += [argv[i + 1] for i, value in enumerate(argv[:-1]) if value == '--remote']
    if len(remotes) > 1:
        raise ValueError('ambiguous source endpoint')
    if remotes:
        from urllib.parse import urlparse
        endpoint = urlparse(remotes[0])
        if endpoint.scheme != 'unix' or endpoint.netloc or endpoint.query or endpoint.fragment:
            raise ValueError('source endpoint is not a private Unix socket')
        expected = endpoint.path
    else:
        home = environment.get('CODEX_HOME') or str(Path(environment['HOME']) / '.codex')
        expected = str(Path(home) / 'app-server-control/app-server-control.sock')
    if args.socket != expected or os.readlink(str(process / 'cwd')) != args.cwd:
        raise ValueError('endpoint or working directory does not match the source')
    identity = private_socket(args.socket)
    connection = Connection(args.socket)
    try:
        if private_socket(args.socket) != identity or process_start(args.pid) != args.start:
            raise ValueError('source changed while connecting')
        connection.rpc('initialize', {'clientInfo': {'name': 'relay_mcp_health', 'version': '0.1'}, 'capabilities': {'experimentalApi': True}})
        loaded = connection.rpc('thread/loaded/list', {}).get('data', [])
        if args.inspect_loaded:
            if len(loaded) > 100:
                raise ValueError('loaded thread inventory exceeds limit')
            threads = []
            for ident in loaded:
                item = connection.rpc('thread/read', {'threadId': ident, 'includeTurns': False})['thread']
                if item.get('cwd') == args.cwd:
                    threads.append({'id': item.get('id'), 'session_id': item.get('sessionId'),
                                    'cwd': item.get('cwd'), 'status': item.get('status'),
                                    'forked_from': item.get('forkedFromId')})
            print(json.dumps({'loaded_count': len(loaded), 'matching_directory_threads': threads}))
            return
        if args.thread not in loaded:
            raise ValueError('exact source thread is not loaded')
        thread = connection.rpc('thread/read', {'threadId': args.thread, 'includeTurns': False})['thread']
        if thread.get('id') != args.thread or thread.get('cwd') != args.cwd:
            raise ValueError('thread identity or working directory changed')
        if args.refresh:
            if not source_owns_listener(args.pid, args.socket):
                raise ValueError('control listener does not belong to the exact source process')
            if loaded != [args.thread] or thread.get('status', {}).get('type') != 'idle':
                raise ValueError('refresh requires the single intended idle thread')
            if process_start(args.pid) != args.start or private_socket(args.socket) != identity:
                raise ValueError('source changed before refresh')
            connection.rpc('config/mcpServer/reload', {})
        result = connection.rpc('mcpServerStatus/list', {'threadId': args.thread, 'serverName': args.server, 'limit': 100, 'detail': 'toolsAndAuthOnly'})
        servers = [{'name': item.get('name'), 'runtime_status': item.get('runtimeStatus'),
                    'tool_count': len(item.get('tools', {})), 'tools_error': item.get('toolsError'),
                    'auth_status': item.get('authStatus')} for item in result.get('data', [])]
        print(json.dumps({'thread': args.thread, 'loaded_count': len(loaded), 'refresh_requested': args.refresh,
                          'servers': servers, 'next_cursor': result.get('nextCursor')}))
    finally:
        connection.sock.close()


if __name__ == '__main__':
    main()
