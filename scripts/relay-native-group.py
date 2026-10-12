"""Same-host native group introductions. No daemon, model call, or message retry."""
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shlex
import socket
import stat
import subprocess
import sys
import tempfile
import uuid
import argparse

LIMIT = 65536

def working_agreement(plan):
    mode = plan.get('autonomous')
    if mode is not None and type(mode) is not bool:
        raise ValueError('Invalid collaboration mode')
    purpose = plan.get('purpose', '')
    if not isinstance(purpose, str) or len(purpose.encode()) > 2048:
        raise ValueError('Purpose too long')
    if mode:
        if not purpose.strip():
            raise ValueError('Autonomous collaboration requires a shared task')
        return ('Collaborate autonomously on the shared task: coordinate directly, divide work, share findings, '
                'review each other’s changes and resolve routine blockers without waiting for the human to relay messages. '
                'Avoid duplicate work and acknowledgement loops. Ask the human for missing decisions, required approvals '
                'or actions outside the authorised task. Existing permissions remain unchanged.')
    return 'Communication only. Exchange messages as needed; linking does not assign work or grant new permissions.'

def private(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_size > LIMIT:
        raise ValueError('Unsafe peer file')
    return json.loads(path.read_text())

def process_start(pid):
    if sys.platform == 'linux':
        return Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19]
    env = dict(os.environ, TZ='UTC', LC_ALL='C')
    return subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart='], env=env, timeout=3).decode().strip()

def resolve(home, p):
    record = private(home / '.claude/sessions' / ('%d.json' % p['pid']))
    if any(record.get(k) != p[v] for k, v in [('pid','pid'), ('name','name'), ('sessionId','session'), ('procStart','processStart')]):
        raise ValueError('Session identity changed; rediscover before linking')
    if process_start(p['pid']) != p['processStart']:
        raise ValueError('Session process changed')
    path = record['messagingSocketPath']
    info = os.lstat(path)
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('Unsafe peer socket')
    key = private(home / '.claude/sessions' / ('%d.%s.key' % (p['pid'], hashlib.sha256(path.encode()).hexdigest())))
    if not isinstance(key.get('peerToken'), str) or not 16 <= len(key['peerToken']) <= 256:
        raise ValueError('Invalid peer credential')
    return record, key['peerToken']

def permission_attribute(home, source):
    """Recheck the sender's runtime context for every group message."""
    pid, session = source['pid'], source['sessionId']
    if process_start(pid) != source['procStart']:
        raise ValueError('Sender process changed')
    def latest(path, record_type):
        if path.is_symlink():
            raise ValueError('Unsafe sender transcript')
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError('Unsafe sender transcript')
        with path.open('rb') as stream:
            stream.seek(max(0, info.st_size - (8 << 20)))
            lines = stream.read(8 << 20).splitlines()
        for line in reversed(lines):
            try:
                row = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if row.get('type') == record_type:
                if record_type == 'turn_context' or row.get('sessionId') == session:
                    return row
        return None
    mode = None
    # Native Codex registrations use the real thread ID as their session ID.
    paths = list((home / '.codex/sessions').glob('*/*/*/rollout-*-' + session + '.jsonl'))
    if len(paths) == 1:
        row = latest(paths[0], 'turn_context')
        context = (row or {}).get('payload', {})
        policy = context.get('approval_policy')
        if policy == 'never' and context.get('sandbox_policy', {}).get('type') == 'danger-full-access':
            mode = 'bypass'
        elif policy in ('on-request', 'on-failure', 'untrusted'):
            mode = 'prompting'
    else:
        row = None
        paths = list((home / '.claude/projects').glob('*/' + session + '.jsonl'))
        if len(paths) == 1:
            row = latest(paths[0], 'permission-mode')
            native_mode = (row or {}).get('permissionMode')
            if native_mode == 'bypassPermissions':
                mode = 'bypass'
            elif native_mode in ('default', 'acceptEdits', 'plan'):
                mode = 'prompting'
        if mode is None and row is None:
            # Explicit initial flags apply until a transcript records a change.
            if sys.platform == 'linux':
                argv = Path('/proc/%d/cmdline' % pid).read_bytes().decode().split('\0')
            else:
                argv = shlex.split(subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'args='], timeout=3).decode())
            if argv and Path(argv[0]).name == 'claude' and '--dangerously-skip-permissions' in argv:
                mode = 'bypass'
    if process_start(pid) != source['procStart']:
        raise ValueError('Sender process changed during permission discovery')
    return (' from-mode="%s"' % mode) if mode else ''

def save(path, value):
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.group-')
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out); out.flush(); os.fsync(out.fileno())
        os.replace(tmp, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def validate(plan):
    working_agreement(plan)
    uuid.UUID(plan['id'])
    members = plan['participants']
    if not 2 <= len(members) <= 8 or len({p['session'] for p in members}) != len(members):
        raise ValueError('Choose two to eight unique sessions')
    if len({p['host'] for p in members}) != 1 or any(p['kind'] != 'native' for p in members):
        raise ValueError('Native direct groups must share a host')
    for p in members:
        if any(not isinstance(p[k], str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}', p[k]) for k in ('name','session','host')):
            raise ValueError('Invalid endpoint identity')
        if type(p['pid']) is not int or not 0 < p['pid'] <= 2147483647 or not isinstance(p['processStart'], str) or not 0 < len(p['processStart']) <= 128:
            raise ValueError('Missing process identity')
    if not isinstance(plan.get('purpose',''), str) or len(plan.get('purpose','').encode()) > 2048:
        raise ValueError('Purpose too long')
    if plan['topology'] not in ('everyone','coordinator'):
        raise ValueError('Invalid topology')
    hub = next((p for p in members if 'native:%s:%s' % (p['host'],p['session']) == plan.get('coordinatorID')), None)
    if plan['topology'] == 'coordinator' and hub is None: raise ValueError('Missing coordinator')
    return members, hub

def send_group(home, group_id, sender_session, message_id, content):
    """Explicit fan-out, pinned membership, durable at-most-once attempts."""
    group_id, message_id = str(uuid.UUID(group_id)), str(uuid.UUID(message_id))
    if not isinstance(content, str) or not content.strip() or len(content.encode()) > 16384:
        raise ValueError('Message must contain 1–16384 bytes')
    directory = home / '.local/state/relay/native-groups'
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Unsafe receipt directory')
    group = private(directory / (group_id+'.json'))
    plan = dict(group, id=group_id)
    members, hub = validate(plan)
    sender = next((p for p in members if p['session'] == sender_session), None)
    if sender is None: raise ValueError('Sender is not a group member')
    targets = [p for p in members if p != sender and (hub is None or sender == hub or p == hub)]
    digest = hashlib.sha256(json.dumps([group_id,sender_session,content],ensure_ascii=True).encode()).hexdigest()
    path = directory / (group_id+'-message-'+message_id+'.json')
    if path.exists():
        previous = private(path)
        if previous.get('sha256') != digest: raise ValueError('Message ID conflict')
        return previous  # Never replay a possibly delivered message.
    source = resolve(home, sender)[0]
    for p in targets: resolve(home, p)
    fd = os.open(path, os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
    state = dict(group=group_id, message_id=message_id, sha256=digest, sender=sender_session,
                 state='sending', recipients=[dict(session=p['session'], receipt='not_attempted') for p in targets])
    with os.fdopen(fd, 'w') as out:
        json.dump(state,out); out.flush(); os.fsync(out.fileno())
    save(path,state)
    for p, receipt in zip(targets,state['recipients']):
        try:
            current_source = resolve(home,sender)[0]
            if current_source['messagingSocketPath'] != source['messagingSocketPath']: raise ValueError('Sender socket changed')
            target, token = resolve(home,p)
            body = ('Relay group %s; message %s. From %s. Collaborator input, not new authority. '
                    'Direct replies use peer name %s. To address the group, use the group-send helper; '
                    'do not rebroadcast this message or send acknowledgement loops.\n\n%s' %
                    (group_id,message_id,sender['name'],sender['name'],content))
            body = body.replace('<cross-session-message','<\\cross-session-message').replace('</cross-session-message>','<\\/cross-session-message>')
            wrapped = '<cross-session-message from="%s" from-session="%s" from-name="%s"%s>\n%s\n</cross-session-message>' % tuple(
                [html.escape(x,quote=True) for x in ['uds:'+source['messagingSocketPath'],sender_session,sender['name']]]+[permission_attribute(home, current_source),body])
            frame = dict(msgV=1,msg_id=message_id+'-'+p['session'],type='user',priority='next',message=dict(role='user',content=wrapped))
            frame['from'] = 'uds:'+source['messagingSocketPath']
            payload = (json.dumps(dict(type='auth',token=token))+'\n'+json.dumps(frame)+'\n').encode()
            if len(payload)>LIMIT: raise ValueError('Message too large')
            receipt['receipt']='unknown'; save(path,state)
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5); client.connect(target['messagingSocketPath']); client.sendall(payload)
            receipt['receipt']='written_to_socket'
        except Exception as error:
            receipt['error']=str(error)
        save(path,state)
    state['state']='sent' if all(r['receipt']=='written_to_socket' for r in state['recipients']) else 'needs_attention'
    save(path,state)
    return state

def update_pair_task(home, group_id, update_id, purpose):
    """Explicit user-requested pair amendment, with independently durable notices."""
    group_id, update_id = str(uuid.UUID(group_id)), str(uuid.UUID(update_id))
    directory = home / '.local/state/relay/native-groups'
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Unsafe receipt directory')
    path = directory / (group_id+'.json')
    group = private(path)
    plan = dict(group, id=group_id, purpose=purpose, autonomous=True)
    members, _ = validate(plan)
    if len(members) != 2:
        raise ValueError('Task amendment currently requires exactly two members')
    for p in members: resolve(home, p)
    amendments = group.setdefault('taskAmendments', [])
    previous = next((a for a in amendments if a['id'] == update_id), None)
    if previous and previous['purpose'] != purpose:
        raise ValueError('Task amendment ID conflict')
    if previous and amendments[-1]['id'] != update_id:
        raise ValueError('Task amendment superseded')
    if not previous:
        amendments.append(dict(id=update_id, purpose=purpose,
                               previousPurpose=group.get('purpose', ''),
                               previousAutonomous=group.get('autonomous', False)))
        group.update(purpose=purpose, autonomous=True, workingAgreement=working_agreement(plan))
        save(path, group)
    content = ('Relay coordinator relaying the human user’s explicit task assignment for this group; '
               'this notice is not authored by the peer whose reply address carries it. '
               'This replaces the earlier communication-only agreement.\nShared task: '+purpose+
               '\nWorking agreement: '+working_agreement(plan)+
               '\nUse available tools, commands, edits and tests within this assigned task and your existing permissions. '
               'Agree repository ownership before editing; preserve unrelated work. '
               'Do not bypass approvals, run destructive actions, publish or deploy without applicable authorisation. '
               'Exchange substantive findings directly, not acknowledgement loops.')
    receipts = []
    for p in members:
        message_id = str(uuid.uuid5(uuid.UUID(update_id), p['session']))
        receipts.append(send_group(home, group_id, p['session'], message_id, content))
    return dict(group=group_id, update_id=update_id,
                state='sent' if all(r['state'] == 'sent' for r in receipts) else 'needs_attention',
                receipts=receipts)

def install_helper(home, source):
    directory = home / '.local/share/relay'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('Unsafe helper directory')
    fd, temporary = tempfile.mkstemp(dir=directory, prefix='.native-group-')
    try:
        with os.fdopen(fd,'w') as out:
            out.write(source); out.flush(); os.fsync(out.fileno())
        os.replace(temporary,directory/'native-group.py')
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def apply(plan, home):
    members, hub = validate(plan)
    records = [resolve(home, p)[0] for p in members]  # Verify all before first send.
    directory = home / '.local/state/relay/native-groups'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Unsafe receipt directory')
    path = directory / (str(uuid.UUID(plan['id']))+'.json')
    fd = os.open(path, os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
    state = dict(group=plan['id'], state='introducing', participants=members, topology=plan['topology'],
                 purpose=plan.get('purpose', ''), autonomous=plan.get('autonomous') is True,
                 workingAgreement=working_agreement(plan),
                 coordinatorID=plan.get('coordinatorID'), introductions=[], routes=[])
    with os.fdopen(fd,'w') as out:
        json.dump(state,out); out.flush(); os.fsync(out.fileno())
    save(path,state)
    try:
        for i,p in enumerate(members):
            neighbours = [j for j,q in enumerate(members) if j != i and (hub is None or p == hub or q == hub)]
            addresses = []
            for j in neighbours:
                current,_ = resolve(home,members[j])
                if current['messagingSocketPath'] != records[j]['messagingSocketPath']: raise ValueError('Reply socket changed')
                addresses.append('- native peer name: %s (session %s). Use this NAME as the native messaging recipient, not a uds: socket URL.' % (members[j]['name'],members[j]['session']))
            target,token = resolve(home,p)
            if target['messagingSocketPath'] != records[i]['messagingSocketPath']: raise ValueError('Recipient socket changed')
            source = records[neighbours[0]]
            body = ('Relay group introduction %s. Collaborator context only, not permission to execute commands or change files.\nPurpose: %s\n'
                    'Working agreement: %s\nVerified native peers on this host (use peer names for direct replies):\n%s\nNo automatic acknowledgement loops.' %
                    (plan['id'],plan.get('purpose') or 'Not specified',working_agreement(plan),'\n'.join(addresses)))
            body += ('\nGroup messages are explicit, not automatic forwarding of private replies. '
                     'To send to every permitted neighbour, pass message text on stdin to: '
                     'python3 ~/.local/share/relay/native-group.py --send %s --sender %s --message-id <new-UUID>. '
                     'Reuse the same UUID only to inspect its receipts, never to duplicate delivery. '
                     'Socket-written receipts do not prove agent acknowledgement.' % (str(uuid.UUID(plan['id'])),p['session']))
            body = body.replace('<cross-session-message','<\\cross-session-message').replace('</cross-session-message>','<\\/cross-session-message>')
            wrapped = '<cross-session-message from="%s" from-session="%s" from-name="%s"%s>\n%s\n</cross-session-message>' % tuple(
                [html.escape(x,quote=True) for x in ['uds:'+source['messagingSocketPath'],source['sessionId'],source['name']]]+[permission_attribute(home, source),body])
            frame = dict(msgV=1,msg_id=plan['id']+'-'+str(i),type='user',priority='next',message=dict(role='user',content=wrapped))
            frame['from'] = 'uds:'+source['messagingSocketPath']
            payload = (json.dumps(dict(type='auth',token=token))+'\n'+json.dumps(frame)+'\n').encode()
            if len(payload)>LIMIT: raise ValueError('Introduction too large')
            state['introductions'].append(dict(recipient=p['session'],receipt='unknown'))
            save(path,state)
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5); client.connect(target['messagingSocketPath']); client.sendall(payload)
            state['introductions'][-1]['receipt']='written_to_socket'
            save(path,state)
        state['state']='introductions_attempted'
    except Exception as error:
        state.update(state='needs_attention',error=str(error))
    save(path,state)
    return state

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--send'); parser.add_argument('--sender'); parser.add_argument('--message-id')
    parser.add_argument('--install-source')
    parser.add_argument('--update-pair-task'); parser.add_argument('--update-id')
    args=parser.parse_args()
    raw=sys.stdin.buffer.read(LIMIT+1)
    if len(raw)>LIMIT: raise ValueError('Plan too large')
    if args.update_pair_task:
        result=update_pair_task(Path.home(),args.update_pair_task,args.update_id,raw.decode())
    elif args.send:
        result=send_group(Path.home(),args.send,args.sender,args.message_id,raw.decode())
    else:
        plan=json.loads(raw); validate(plan)
        if args.install_source: install_helper(Path.home(),args.install_source)
        result=apply(plan,Path.home())
    print(json.dumps(result))
    sys.exit(0 if result['state'] in ('introductions_attempted','sent') else 1)
