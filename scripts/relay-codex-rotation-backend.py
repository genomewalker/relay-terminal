"""One-shot Codex app-server lifecycle adapter for a trusted Relay parent.

No backend launch, implicit source resume, retries, terminal input, or deletion.
An ambiguous result must be reconciled by the durable rotation journal.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import websockets

LIMIT = 65536
_spec = importlib.util.spec_from_file_location('relay_ingress', Path(__file__).with_name('codex-desktop-deliver.py'))
ingress = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ingress)


def identifier(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 110 or any(ord(c) < 33 for c in value):
        raise ValueError('invalid exact thread identity')
    return value


class Backend:
    def __init__(self, ws):
        self.ws = ws
        self.sequence = 0
        self.events = []

    async def rpc(self, method, params):
        self.sequence += 1
        ident = self.sequence
        await self.ws.send(json.dumps(dict(id=ident, method=method, params=params)))
        async for raw in self.ws:
            value = json.loads(raw)
            if value.get('id') == ident:
                if 'error' in value:
                    raise RuntimeError('app-server rejected lifecycle operation')
                return value['result']
            self.events.append(value)
            if len(self.events) > 256:
                raise ValueError('too many lifecycle notifications')
        raise ConnectionError('response lost; reconciliation required')

    async def inspect(self, thread, cwd, descendants=True):
        loaded = await self.rpc('thread/loaded/list', {})
        if thread not in loaded.get('data', []):
            raise ValueError('source is not loaded; never implicitly resume it')
        result = (await self.rpc('thread/read', dict(threadId=thread, includeTurns=False)))['thread']
        if (result.get('id') != thread or result.get('sessionId') != thread
                or result.get('cwd') != cwd or result.get('forkedFromId') is not None
                or result.get('status', {}).get('type') != 'idle'):
            raise ValueError('source identity, root or idle boundary changed')
        if descendants:
            # Archive includes descendants. Refuse the entire operation if any
            # exist; Relay does not infer authorization for them.
            for archived in (False, True):
                children = await self.rpc('thread/list', dict(parentThreadId=thread, archived=archived, limit=1))
                if children.get('data') or children.get('nextCursor') is not None:
                    raise ValueError('source has descendants; retirement scope is not isolated')
        return dict(idle=True, root=True, no_descendants=descendants)

    async def load(self, thread, args):
        capsule = args['capsule']
        digest = hashlib.sha256(capsule.encode()).hexdigest()
        if digest != args['sha256']:
            raise ValueError('capsule hash mismatch')
        # Fresh threads may unload after the creating client disconnects.
        # Only the exact newly bound destination is allowed to resume here.
        await self.rpc('thread/resume', dict(threadId=thread))
        await self.inspect(thread, args['cwd'], descendants=False)
        marker = 'Relay-Capsule-Loaded: ' + digest
        turn = await self.rpc('turn/start', {
            'threadId': thread,
            'input': [{'type': 'text', 'text': 'Receive the saved handoff capsule supplied as Relay tool output. Read it, then reply with exactly ' + marker + '. Do not execute tools or begin the saved work in this receipt turn.'}],
            'toolOutput': {'namespace': 'relay', 'name': 'rotation_capsule', 'output': capsule},
        })
        turn_id = turn['turn']['id']
        text = []
        while True:
            value = self.events.pop(0) if self.events else json.loads(await self.ws.recv())
            method, params = value.get('method'), value.get('params', {})
            if params.get('threadId') != thread:
                continue
            if method == 'item/completed' and params.get('turnId') == turn_id:
                item = params.get('item', {})
                if item.get('type') == 'agentMessage':
                    text.append(item.get('text', ''))
                elif item.get('type') not in ('userMessage', 'reasoning', 'contextCompaction'):
                    raise ValueError('receipt turn attempted work; reconciliation required')
            if method == 'turn/completed' and params.get('turn', {}).get('id') == turn_id:
                if params['turn'].get('status') != 'completed' or '\n'.join(text).strip() != marker:
                    raise ValueError('capsule receipt not acknowledged')
                return dict(thread_id=thread, completed=True, sha256=digest, turn_id=turn_id)


async def perform(options, args):
    path = ingress.check_socket(options.socket)
    identity = os.stat(path)
    if (identity.st_dev, identity.st_ino) != (options.device, options.inode):
        raise ValueError('enrolled app-server incarnation changed')
    cwd = args['cwd']
    if not isinstance(cwd, str) or not Path(cwd).is_absolute():
        raise ValueError('absolute enrolled working directory required')
    if 'code_head' in args:
        actual = subprocess.run(['git', '-C', cwd, 'rev-parse', 'HEAD'], capture_output=True,
                                text=True, timeout=10, check=True).stdout.strip()
        if actual != args['code_head']:
            raise ValueError('enrolled repository HEAD changed')
    async with asyncio.timeout(110):
        async with websockets.unix_connect(path, compression=None, max_size=LIMIT) as ws:
            identity = os.stat(path)
            if (identity.st_dev, identity.st_ino) != (options.device, options.inode):
                raise ValueError('backend changed during connection')
            backend = Backend(ws)
            await backend.rpc('initialize', dict(clientInfo=dict(name='relay_rotation', version='1'),
                                                capabilities=dict(experimentalApi=True)))
            await ws.send(json.dumps(dict(method='initialized', params={})))
            if options.operation == 'inspect':
                return await backend.inspect(identifier(args['thread_id']), cwd)
            if options.operation == 'start':
                await backend.inspect(identifier(args['source_thread_id']), cwd)
                start = args['start_parameters']
                if not isinstance(start, dict) or start.get('cwd') != cwd:
                    raise ValueError('retained source configuration required')
                result = await backend.rpc('thread/start', start)
                thread = result['thread']
                identifier(thread['id'])
                if thread.get('sessionId') != thread['id']:
                    raise ValueError('fresh destination is not a root')
                return dict(thread_id=thread['id'], session_id=thread['sessionId'])
            if options.operation == 'load':
                return await backend.load(identifier(args['thread_id']), args)
            if options.operation == 'archive':
                thread = identifier(args['thread_id'])
                await backend.inspect(thread, cwd)
                await backend.rpc('thread/archive', dict(threadId=thread))
                return dict(thread_id=thread, archived=True)
            raise ValueError('unsupported lifecycle operation')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--device', type=int, required=True)
    parser.add_argument('--inode', type=int, required=True)
    parser.add_argument('--operation', choices=('inspect', 'start', 'load', 'archive'), required=True)
    options = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError('request too large')
        result = asyncio.run(perform(options, json.loads(raw)))
    except Exception as error:
        print(json.dumps(dict(status='reconciliation_required', reason=type(error).__name__)))
        sys.exit(1)
    print(json.dumps(result))
