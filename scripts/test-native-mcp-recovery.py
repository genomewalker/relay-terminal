#!/usr/bin/env python3
"""Actual native MCP recovery fixture; never submits a model turn.

Uses a private HOME/CODEX_HOME and one ephemeral app-server thread. One MCP
process initially fails initialization; repairing its private fixture must
recover the catalog without restarting the thread or its healthy MCP peer.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


FIXTURE = '''import json,os,sys
from pathlib import Path
root=Path(sys.argv[1]);name=sys.argv[2]
with (root/(name+'.starts')).open('a') as f:f.write(str(os.getpid())+'\\n')
for line in sys.stdin:
 request=json.loads(line);ident=request.get('id');method=request.get('method')
 if name=='broken' and not (root/'repaired').exists():sys.exit(1)
 if ident is None:continue
 if method=='initialize':
  result={'protocolVersion':request['params']['protocolVersion'],'capabilities':{'tools':{}},'serverInfo':{'name':name,'version':'1'}}
 elif method=='tools/list':
  result={'tools':[{'name':'fixture_read','description':'Read-only fixture','inputSchema':{'type':'object','properties':{}},'annotations':{'readOnlyHint':True}}]}
 elif method=='ping':result={}
 else:
  print(json.dumps({'jsonrpc':'2.0','id':ident,'error':{'code':-32601,'message':'unsupported fixture request'}}),flush=True);continue
 print(json.dumps({'jsonrpc':'2.0','id':ident,'result':result}),flush=True)
'''


class RPC:
    def __init__(self, process):
        self.process = process
        self.incoming = queue.Queue()
        self.events = collections.deque(maxlen=4096)
        self.sequence = 0

        def read():
            try:
                for line in process.stdout:
                    self.incoming.put(json.loads(line))
            except Exception as error:
                self.incoming.put(error)
            finally:
                self.incoming.put(EOFError('fixture app server closed'))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def receive(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('native recovery fixture timed out')
        value = self.incoming.get(timeout=remaining)
        if isinstance(value, Exception):
            raise value
        if value.get('method') == 'turn/started':
            raise AssertionError('recovery unexpectedly started a model turn')
        return value

    def call(self, method, params):
        self.sequence += 1
        ident = self.sequence
        self.process.stdin.write(json.dumps({'id': ident, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 30
        while True:
            value = self.receive(deadline)
            if value.get('id') == ident:
                if 'error' in value:
                    raise AssertionError((method, value['error']))
                return value['result']
            self.events.append(value)

    def status_event(self, thread, server, status, timeout=80):
        def matches(value):
            p = value.get('params', {})
            return (value.get('method') == 'mcpServer/startupStatus/updated'
                    and p.get('threadId') == thread and p.get('name') == server
                    and p.get('status') == status)
        for value in self.events:
            if matches(value):
                return
        deadline = time.monotonic() + timeout
        while True:
            value = self.receive(deadline)
            self.events.append(value)
            if matches(value):
                return


def starts(root, name):
    return (root / (name + '.starts')).read_text().splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--result', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if not binary.with_name('codex-peer-worker').is_file():
        raise ValueError('matching native worker must be beside Codex')
    hashes = {}
    for name in ('codex', 'codex-peer-worker', 'codex-code-mode-host'):
        digest = hashlib.sha256()
        with binary.with_name(name).open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        hashes[name] = digest.hexdigest()
    with tempfile.TemporaryDirectory(prefix='relay-mcp-recovery-') as directory:
        root = Path(directory)
        home = root / 'home'
        home.mkdir(mode=0o700)
        codex_home = home / '.codex'
        codex_home.mkdir(mode=0o700)
        fixture = root / 'fixture.py'
        fixture.write_text(FIXTURE)
        config = ''
        for server, name in [('relayDesktopR', 'broken'), ('healthy', 'healthy')]:
            config += ('[mcp_servers.' + server + ']\ncommand = ' + json.dumps(sys.executable)
                       + '\nargs = ' + json.dumps([str(fixture), str(root), name])
                       + '\nstartup_timeout_sec = 5\n')
        (codex_home / 'config.toml').write_text(config)
        environment = dict(os.environ, HOME=str(home), CODEX_HOME=str(codex_home), RELAY_NATIVE_MESSAGES='1')
        stderr_path = args.result.with_suffix('.stderr.log')
        args.result.parent.mkdir(parents=True, exist_ok=True)
        with stderr_path.open('w') as stderr:
            process = subprocess.Popen([str(binary), 'app-server', '--listen', 'stdio://'],
                                       env=environment, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=stderr, text=True, bufsize=1)
            try:
                rpc = RPC(process)
                rpc.call('initialize', {'clientInfo': {'name': 'relay_recovery_fixture', 'version': '1'},
                                        'capabilities': {'experimentalApi': True}})
                result = rpc.call('thread/start', {'cwd': str(root), 'ephemeral': True,
                                                   'approvalPolicy': 'never', 'sandbox': 'read-only'})
                thread = result['thread']['id']
                rpc.status_event(thread, 'healthy', 'ready', timeout=30)
                rpc.status_event(thread, 'relayDesktopR', 'failed', timeout=30)
                before = starts(root, 'healthy')
                (root / 'repaired').write_text('fixture helper repaired\n')
                rpc.status_event(thread, 'relayDesktopR', 'ready')
                inventory = rpc.call('mcpServerStatus/list', {'threadId': thread, 'serverName': 'relayDesktopR',
                                                             'detail': 'toolsAndAuthOnly', 'limit': 100})
                server = next(item for item in inventory['data'] if item['name'] == 'relayDesktopR')
                assert len(server['tools']) == 1 and server.get('toolsError') is None, server
                assert starts(root, 'healthy') == before, 'healthy MCP process restarted'
                assert len(starts(root, 'broken')) >= 2, 'failed MCP process was not replaced'
                loaded = rpc.call('thread/loaded/list', {})['data']
                assert loaded == [thread], 'thread identity changed during recovery'
                args.result.write_text(json.dumps({'passed': True, 'binary': str(binary),
                                                   'files': hashes, 'thread': thread, 'tool_count': 1,
                                                   'healthy_processes_preserved': True,
                                                   'failed_process_starts': len(starts(root, 'broken')),
                                                   'model_turns': 0}))
                print('PASS: failed MCP recovered, healthy process and thread preserved; no model turn')
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()  # Only this fixture's private child.
                    process.wait(timeout=5)


if __name__ == '__main__':
    main()
