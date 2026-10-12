"""Real worker/link round trip in isolated registries; no model calls."""
import json
import os
import pathlib
import select
import socket
import subprocess
import sys
import tempfile
import time

buffers = {}
if len(sys.argv) == 1:
    sys.argv.extend([str(pathlib.Path(__file__).with_name('fixtures') / 'peer-worker.py'),
                     '/Applications/Relay.app/Contents/MacOS/relay-peer-link'])
if len(sys.argv) != 3:
    raise SystemExit('usage: test-peer-link.py [WORKER PEER_LINK]')
def receive(p):
    deadline = time.monotonic() + 10
    data = buffers.get(p.pid, b'')
    while b'\n' not in data:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([p.stdout], [], [], remaining)[0], 'response timeout'
        chunk = os.read(p.stdout.fileno(), 65536)
        assert chunk, 'process exited'
        data += chunk
    line, buffers[p.pid] = data.split(b'\n', 1)
    return json.loads(line)

def send(p, **data):
    p.stdin.write(json.dumps(data).encode() + b'\n')
    p.stdin.flush()

with tempfile.TemporaryDirectory(prefix='relay-link-test-', dir='/tmp') as tmp:
    processes = []
    links = []
    try:
        workers = []
        for name in ('a', 'b'):
            home = pathlib.Path(tmp) / name
            home.mkdir()
            p = subprocess.Popen([sys.argv[1], name, str(home), str(home)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            processes.append(p)
            workers.append((p, home, name))
            assert receive(p) == {'ready': True}
        sockets = socket.socketpair()
        for (worker, home, name), stream in zip(workers, sockets):
            link = subprocess.Popen([sys.argv[2], '--serve', '--home', str(home), '--name', 'codex-' + name,
                '--session', name, '--pid', str(worker.pid), '--label', name], stdin=stream, stdout=stream)
            processes.append(link)
            links.append(link)
        for stream in sockets:
            stream.close()
        a, b = workers[0][0], workers[1][0]
        deadline = time.monotonic() + 10
        while True:
            send(a, id='list', op='list')
            peers = receive(a)['result']
            if any(p['name'] == 'b--codex-b' for p in peers):
                break
            assert time.monotonic() < deadline, 'proxy not registered'
            time.sleep(.05)
        for index in range(20):
            send(a, id=str(index), op='send', recipient='b--codex-b', content='request-' + str(index))
            assert receive(a)['result'] == 'sent'
            msg = receive(b)
            assert msg['sender'] == 'a--codex-a' and msg['content'] == 'request-' + str(index), msg
            send(b, id=str(index), op='send', recipient=msg['sender'], content='reply-' + str(index))
            assert receive(b)['result'] == 'sent'
            msg = receive(a)
            assert msg['sender'] == 'b--codex-b' and msg['content'] == 'reply-' + str(index), msg
        links[0].terminate()
        for link in links:
            link.wait(timeout=10)
        send(a, id='offline', op='list')
        assert not receive(a)['result'], 'offline proxy remained discoverable'
        send(a, id='offline-send', op='send', recipient='b--codex-b', content='must not queue')
        assert 'error' in receive(a)
        print('PASS: 20 bidirectional native round trips; host attribution; disconnect cleanup; offline send fails')
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=10)
