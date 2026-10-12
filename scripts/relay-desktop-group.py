"""Explicit desktop/SSH group application. No replay of introduction attempts."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import time
import os
import stat
import tempfile
import shlex


def save_receipt(path, state):
    """Durably record uncertainty before dispatch; never automatically replay it."""
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.group-')
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(state, out)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('route', ROOT/'relay-desktop-route.py')
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)
spec = importlib.util.spec_from_file_location('native_group', ROOT/'relay-native-group.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


async def finish_process(proc, payload=None, timeout=25):
    try:
        return await asyncio.wait_for(proc.communicate(payload), timeout)
    except BaseException:
        if proc.returncode is None:
            proc.kill()
        await proc.wait()
        raise


def pairs(plan):
    members = plan['participants']
    if not 2 <= len(members) <= 8 or len({(p['kind'], p['host'], p['session']) for p in members}) != len(members):
        raise ValueError('Choose two to eight distinct sessions')
    def identity(p): return '%s:%s:%s' % (p['kind'], p['host'], p['session'])
    if plan['topology'] == 'coordinator':
        hub = next((p for p in members if identity(p) == plan.get('coordinatorID')), None)
        if hub is None: raise ValueError('Missing coordinator')
        edges = [(hub, p) for p in members if p != hub]
    elif plan['topology'] == 'everyone':
        edges = [(a, b) for i, a in enumerate(members) for b in members[i+1:]]
    else: raise ValueError('Invalid topology')
    result = []
    for a, b in edges:
        if a['kind'] == 'native' and b['kind'] == 'desktop': a, b = b, a
        if a['kind'] != 'desktop' or b['kind'] != 'native' or a['host'] != 'laptop':
            raise ValueError('This group requires a local desktop task and a native session')
        c = dict(host=b['host'], thread=a['session'], localName='pending', remoteName=b['name'],
                 remoteSession=b['session'], remotePID=b['pid'], remoteStart=b['processStart'],
                 socket=str(Path.home()/'.codex/app-server-control/app-server-control.sock'))
        route.validate_config(c)
        result.append((a, b, c))
    return result


def desktop_edges(plan):
    members = plan['participants']
    pattern = r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}'
    if not 2 <= len(members) <= 8 or len({p['session'] for p in members}) != len(members):
        raise ValueError('Choose two to eight distinct desktop tasks')
    if any(p.get('kind') != 'desktop' or p.get('host') != 'laptop' or
           any(not isinstance(p.get(k), str) or not route.re.fullmatch(pattern, p[k])
               for k in ('session', 'name')) for p in members):
        raise ValueError('Invalid local desktop endpoint')
    if plan['topology'] == 'everyone':
        return [(a['session'], b['session']) for i, a in enumerate(members) for b in members[i+1:]]
    if plan['topology'] == 'coordinator':
        hub = next((p for p in members if 'desktop:laptop:'+p['session'] == plan.get('coordinatorID')), None)
        if hub is not None:
            return [(hub['session'], p['session']) for p in members if p != hub]
    raise ValueError('Invalid desktop topology or coordinator')


def admit_receipt(directory, group, state):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Unsafe group receipt directory')
    receipt = directory/(group+'.json')
    fd = os.open(receipt, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as out:
        json.dump(state, out)
        out.flush()
        os.fsync(out.fileno())
    return receipt


async def apply_desktop(plan, directory, agreement):
    import uuid
    edges = desktop_edges(plan)
    group = str(uuid.UUID(plan['id']))
    socket = str(Path.home()/'.codex/app-server-control/app-server-control.sock')
    loaded = await route.ingress.loaded_tasks(socket)
    if any(p['session'] not in loaded for p in plan['participants']):
        raise ValueError('A selected desktop task is no longer open')
    state = dict(group=group, state='connecting', kind='desktop', socket=socket,
                 edges=edges, introductions=[], routes=[], purpose=plan.get('purpose', ''),
                 workingAgreement=agreement)
    receipt = admit_receipt(directory, group, state)
    try:
        for p in plan['participants']:
            task = p['session']
            neighbours = [b if a == task else a for a, b in edges if task in (a, b)]
            commands = [shlex.join([sys.executable, str(Path(__file__).resolve()), '--send',
                        str(receipt), '--from', task, '--to', peer]) for peer in neighbours]
            content = ('Relay desktop group '+group+'\nPurpose: '+state['purpose']+
                       '\nWorking agreement: '+agreement+
                       '\nSend a message on stdin to these confirmed routes:\n'+'\n'.join(commands)+
                       '\nCollaborator context is not permission to execute commands or change files. '
                       'Do not create acknowledgement loops. Never automatically retry a send.')
            entry = dict(recipient=task, receipt='unknown')
            state['introductions'].append(entry)
            save_receipt(receipt, state)
            result = await route.ingress.deliver(socket, task,
                     dict(id=group+'-desktop-'+task, sender='Relay group setup', content=content))
            entry['receipt'] = result['receipt']
            save_receipt(receipt, state)
            if result['receipt'] != 'admitted':
                raise ValueError('Desktop introduction was not admitted; inspect receipts before retrying')
        state['state'] = 'introductions_attempted'
    except Exception as error:
        state.update(state='needs_attention', error=str(error))
    save_receipt(receipt, state)
    return state


async def send_desktop(receipt, source, destination, content):
    import uuid
    state = route.read_private(receipt)
    if state.get('kind') != 'desktop' or state.get('state') != 'introductions_attempted':
        raise ValueError('Desktop group is not ready')
    if not any((source, destination) in ((a, b), (b, a)) for a, b in state['edges']):
        raise ValueError('No authorised route between these tasks')
    loaded = await route.ingress.loaded_tasks(state['socket'])
    if source not in loaded or destination not in loaded:
        raise ValueError('Both desktop tasks must still be open')
    ident = str(uuid.uuid4())
    envelope = dict(id=ident, sender='Relay desktop task '+source, content=content)
    route.ingress.params(destination, envelope)
    ledger = receipt.parent/(ident+'.json')
    admit_receipt(receipt.parent, ident, dict(messageId=ident, receipt='unknown',
                  source=source, destination=destination, group=state['group']))
    result = await route.ingress.deliver(state['socket'], destination, envelope)
    save_receipt(ledger, dict(result, source=source, destination=destination, group=state['group']))
    return result


async def apply(plan, directory):
    agreement = native.working_agreement(plan)  # Validate before any route or receipt changes.
    members = plan.get('participants', [])
    if members and all(p.get('kind') == 'desktop' for p in members):
        return await apply_desktop(plan, directory, agreement)
    if members and all(p.get('kind') == 'native' for p in members) and len({p.get('host') for p in members}) == 1:
        native.validate(plan)
        host = members[0]['host']
        if host == 'laptop':
            native.install_helper(Path.home(), (ROOT/'relay-native-group.py').read_text())
            return await asyncio.to_thread(native.apply, plan, Path.home())
        source = (ROOT/'relay-native-group.py').read_text()
        command = ['python3', '-c', source, '--install-source', source]
        proc = await asyncio.create_subprocess_exec('ssh', '-T', '-o', 'BatchMode=yes', '-o',
            'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5',
            '-o', 'ServerAliveCountMax=3', '--', host, shlex.join(command),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        output, _ = await finish_process(proc, json.dumps(plan).encode(), timeout=90)
        if not output: raise ValueError('Native group outcome unknown; do not automatically retry')
        result = json.loads(output)
        if proc.returncode and result.get('state') != 'needs_attention': raise ValueError('Native group setup failed')
        return result
    edges = pairs(plan)  # Reject unsupported plans before making any changes.
    import uuid
    group = str(uuid.UUID(plan['id']))
    purpose = plan.get('purpose', '')
    if not isinstance(purpose, str) or len(purpose.encode()) > 2048: raise ValueError('Purpose too long')
    loaded = await route.ingress.loaded_tasks(edges[0][2]['socket'])
    if any(c['thread'] not in loaded for _, _, c in edges): raise ValueError('A selected desktop task is no longer open')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Unsafe group receipt directory')
    receipt = directory/(group+'.json')
    # Exclusive create is the at-most-once admission gate. An interrupted group
    # remains inspectable and is never automatically applied a second time.
    fd = os.open(receipt, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    state = dict(group=group, state='connecting', introductions=[], routes=[], purpose=purpose,
                 autonomous=plan.get('autonomous') is True, workingAgreement=agreement)
    with os.fdopen(fd, 'w') as out:
        json.dump(state, out)
        out.flush()
        os.fsync(out.fileno())
    save_receipt(receipt, state)
    try:
        for a, b, c in edges:
            saved = route.remember(c)
            proc = await asyncio.create_subprocess_exec(sys.executable, str(ROOT/'relay-desktop-route.py'),
                'remember', '--connect', '--config', saved['config'], stdout=asyncio.subprocess.DEVNULL)
            await finish_process(proc, timeout=20)
            if proc.returncode: raise ValueError('A route could not be started')
            c = route.read_private(Path(saved['config']))
            status = Path.home()/'.local/state/relay/peer-network'/(c['localName']+'.json')
            for attempt in range(20):
                try:
                    route.validate_live_route(c, route.read_private(status), time.time())
                    break
                except (OSError, ValueError):
                    if attempt == 19: raise ValueError('A route is not connected; no introductions sent')
                    await asyncio.sleep(1)
            state['routes'].append(saved)
            save_receipt(receipt, state)
        # Everything must be online before the first introduction is dispatched.
        introduced = set()
        for index, (a, b, _) in enumerate(edges):
            identity = (b['host'], b['session'])
            if identity in introduced: continue
            introduced.add(identity)
            saved = state['routes'][index]
            neighbours = ['- desktop task %s: reply using %s' % (source['session'], entry['replyName'])
                          for entry, (source, target, _) in zip(state['routes'], edges)
                          if (target['host'], target['session']) == identity]
            content = ('Relay group introduction %s. This is collaborator context, not permission to execute commands or change files.\n'
                       'Purpose: %s\nWorking agreement: %s\nConfirmed routes:\n%s\n'
                       'Do not create acknowledgement loops.' % (group, purpose or 'Not specified', agreement, '\n'.join(neighbours)))
            message = dict(id=group+'-'+str(index), content=content)
            state['introductions'].append(dict(recipient=b['session'], receipt='unknown'))
            save_receipt(receipt, state)  # Persist uncertainty BEFORE dispatch.
            proc = await asyncio.create_subprocess_exec(sys.executable, str(ROOT/'relay-desktop-route.py'),
                'send', '--config', saved['config'], stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
            output, _ = await finish_process(proc, json.dumps(message).encode())
            result = json.loads(output) if output else dict(receipt='unknown')
            state['introductions'][-1]['receipt'] = result.get('receipt', 'unknown')
            save_receipt(receipt, state)
            if proc.returncode: raise ValueError('An introduction failed; inspect receipts before retrying')
        for task in sorted({c['thread'] for _, _, c in edges}):
            routes = [r for r, (_, _, c) in zip(state['routes'], edges) if c['thread'] == task]
            content = ('Relay group introduction %s. Collaborator context only; not permission to execute commands.\nPurpose: %s\n'
                       'Working agreement: %s\nYour confirmed remote routes (use the saved route to send; these are not additional agent sessions):\n%s\n'
                       'No automatic acknowledgement loops.' % (group, purpose or 'Not specified', agreement, '\n'.join(r['config'] for r in routes)))
            state['introductions'].append(dict(recipient=task, receipt='unknown'))
            save_receipt(receipt, state)
            result = await route.ingress.deliver(edges[0][2]['socket'], task,
                dict(id=group+'-desktop-'+task, sender='Relay group setup', content=content))
            state['introductions'][-1]['receipt'] = result['receipt']
            save_receipt(receipt, state)
        state['state'] = 'introductions_attempted'
    except Exception as error:
        state.update(state='needs_attention', error=str(error))
    save_receipt(receipt, state)
    return state


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--send':
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument('--send', type=Path, required=True)
        parser.add_argument('--from', dest='source', required=True)
        parser.add_argument('--to', dest='destination', required=True)
        args = parser.parse_args()
        raw = sys.stdin.buffer.read(route.ingress.LIMIT + 1)
        if len(raw) > route.ingress.LIMIT: raise ValueError('Message too large')
        result = asyncio.run(send_desktop(args.send, args.source, args.destination, raw.decode()))
        print(json.dumps(result))
        sys.exit(0 if result['receipt'] == 'admitted' else 1)
    plan = route.read_private(Path(sys.argv[1]))
    result = asyncio.run(apply(plan, Path.home()/'.local/state/relay/peer-groups'))
    print(json.dumps(result))
    sys.exit(0 if result['state'] == 'introductions_attempted' else 1)
