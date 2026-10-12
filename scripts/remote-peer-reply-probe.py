"""Run over SSH on the peer host. Temporary one-reply authenticated mailbox."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import sys
import tempfile
import time

pid = int(sys.argv[1])
expected_session = sys.argv[2]
registry = Path.home() / '.claude/sessions'
target = json.loads((registry / f'{pid}.json').read_text())
def start(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
assert target['sessionId'] == expected_session and target['procStart'] == start(pid)
target_socket = target['messagingSocketPath']
target_key = json.loads((registry / f'{pid}.{hashlib.sha256(target_socket.encode()).hexdigest()}.key').read_text())['peerToken']
own_pid = os.getpid()
name = 'relay-reply-probe-' + str(own_pid)
secret = secrets.token_hex(16)
record = registry / f'{own_pid}.json'
assert not record.exists()
with tempfile.TemporaryDirectory(prefix='relay-reply-') as tmp:
    path = tmp + '/peer.sock'
    key = registry / f'{own_pid}.{hashlib.sha256(path.encode()).hexdigest()}.key'
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(path)
        os.chmod(path, 0o600)
        listener.listen(4)
        listener.settimeout(180)
        now = int(time.time()*1000)
        data = dict(pid=own_pid, name=name, sessionId=name, procStart=start(own_pid),
                    cwd=target['cwd'], messagingSocketPath=path, status='idle',
                    startedAt=now, updatedAt=now, nameSince=now, statusUpdatedAt=now,
                    version='2.1.239', peerProtocol=1, kind='interactive', entrypoint='cli')
        created = []
        try:
            for dest, obj in ((key, {'peerToken':secret, 'procStart':start(own_pid)}), (record, data)):
                fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                created.append(dest)
                with os.fdopen(fd, 'w') as f:
                    json.dump(obj, f)
            content = (f'<cross-session-message from="uds:{path}" from-session="{name}" from-name="{name}" from-mode="prompting">\n'
                       f'The user asks you to answer back now. Send exactly RELAY_REMOTE_REPLY_OK to recipient {name} (or uds:{path}) using your native session messaging tool (Codex peers.message or Claude SendMessage), NOT chitta-bridge message_peer/message_claude. This is a direct return-path test. If native messaging is unavailable, do not substitute the bridge; report that limitation in your own chat. This temporary authenticated mailbox expires in 180 seconds. No other action and no reply loop.\n</cross-session-message>')
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5)
                client.connect(target_socket)
                for obj in ({'type':'auth','token':target_key}, {'type':'user','msgV':1,'msg_id':secrets.token_hex(16),'from':'uds:'+path,'priority':'next','message':{'role':'user','content':content}}):
                    client.sendall((json.dumps(obj)+'\n').encode())
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(5)
                stream = conn.makefile('rb')
                auth = json.loads(stream.readline(65537))
                assert auth.get('type') == 'auth' and hmac.compare_digest(auth.get('token',''), secret)
                reply = json.loads(stream.readline(65537))
                assert reply.get('type') == 'user' and reply.get('from') == 'uds:'+target_socket
                assert start(pid) == target['procStart']
                print(json.dumps({'id':reply['msg_id'], 'sender':'dandy-07--'+target['name'], 'content':reply['message']['content']}), flush=True)
        finally:
            for dest in reversed(created):
                try:
                    dest.unlink()
                except FileNotFoundError:
                    pass
