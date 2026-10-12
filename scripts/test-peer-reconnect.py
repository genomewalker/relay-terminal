"""Fault-inject a disposable SSH substitute, never the user's live SSH links."""
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time

if len(sys.argv) == 1:
    sys.argv.extend([str(pathlib.Path(__file__).with_name('fixtures') / 'peer-worker.py'),
                     '/Applications/Relay.app/Contents/MacOS/relay-peer-link'])
if len(sys.argv) != 3:
    raise SystemExit('usage: test-peer-reconnect.py [WORKER PEER_LINK]')

def read(p):
    assert select.select([p.stdout], [], [], 10)[0], 'worker timed out'
    return json.loads(p.stdout.readline())

def send(p, **v):
    p.stdin.write(json.dumps(v).encode() + b'\n')
    p.stdin.flush()

with tempfile.TemporaryDirectory(prefix='relay-reconnect-', dir='/tmp') as temp:
    root = pathlib.Path(temp)
    children = []
    try:
        workers = []
        for name in ('a', 'b'):
            home = root / name
            home.mkdir()
            p = subprocess.Popen([sys.argv[1], name, str(home), str(home)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            children.append(p)
            workers.append(p)
            assert read(p) == {'ready': True}
        a, b = workers
        # The fake SSH executes a genuine remote endpoint but records its own PID
        # so the test can cut precisely this disposable transport connection.
        remote = [sys.argv[2], '--serve', '--home', str(root/'b'), '--name', 'codex-b', '--session', 'b',
                  '--pid', str(b.pid), '--label', 'remote', '--expected-name', 'local--codex-a', '--expected-session', 'a']
        helper = root / 'ssh'
        helper.write_text('#!' + sys.executable + '\nimport os,pathlib\n' +
            'pathlib.Path(' + repr(str(root/'remote.pid')) + ').write_text(str(os.getpid()))\n' +
            'os.execv(' + repr(sys.argv[2]) + ', ' + repr(remote) + ')\n')
        helper.chmod(0o700)
        link = subprocess.Popen([sys.argv[2], '--home', str(root/'a'), '--name', 'codex-a', '--session', 'a',
            '--pid', str(a.pid), '--label', 'local', '--host', 'test-host', '--remote-name', 'codex-b',
            '--remote-session', 'b', '--remote-pid', str(b.pid), '--remote-label', 'remote', '--retries', '2'],
            env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH']})
        children.append(link)
        status = root/'a'/'.local/state/relay/peer-network'/f'{link.pid}.json'
        def wait_online(attempt):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                assert link.poll() is None, 'supervisor exited'
                try:
                    s = json.loads(status.read_text())
                    if s['state'] == 'online' and s['attempt'] == attempt:
                        return s
                except (OSError, ValueError):
                    pass
                time.sleep(.05)
            raise AssertionError('link did not recover')
        wait_online(0)
        send(a, id='before', op='send', recipient='remote--codex-b', content='before')
        assert read(a)['result'] == 'sent'
        assert read(b)['content'] == 'before'
        remote_pid = int((root/'remote.pid').read_text())
        os.kill(remote_pid, signal.SIGTERM)
        wait_online(1)
        assert int((root/'remote.pid').read_text()) != remote_pid
        assert not select.select([b.stdout], [], [], .2)[0], 'replayed old message'
        send(a, id='after', op='send', recipient='remote--codex-b', content='after')
        assert read(a)['result'] == 'sent'
        msg = read(b)
        assert msg['content'] == 'after' and msg['sender'] == 'local--codex-a'
        send(b, id='reply', op='send', recipient=msg['sender'], content='recovered')
        assert read(b)['result'] == 'sent'
        assert read(a)['content'] == 'recovered'
        link.terminate()
        link.wait(timeout=10)
        assert json.loads(status.read_text())['state'] == 'stopped'
        print('PASS: connection loss, bounded reconnect, new remote helper, no replay, bidirectional recovery, stopped status')
    finally:
        for p in reversed(children):
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=10)
