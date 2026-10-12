import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('rotation_backend', Path(__file__).with_name('relay-codex-rotation-backend.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FixtureSocket:
    def __init__(self, children=False, active=False, lost=False):
        self.children, self.active, self.lost = children, active, lost
        self.responses, self.calls = [], []

    async def send(self, raw):
        request = json.loads(raw)
        self.calls.append(request)
        method, params = request['method'], request['params']
        if self.lost:
            return
        if method == 'thread/loaded/list':
            result = {'data': ['old-1', 'new-1']}
        elif method == 'thread/read':
            ident = params['threadId']
            result = {'thread': {'id': ident, 'sessionId': ident, 'cwd': '/project',
                                 'status': {'type': 'active' if self.active else 'idle'}}}
        elif method == 'thread/list':
            result = {'data': [{'id': 'child-1'}] if self.children else [], 'nextCursor': None}
        else:
            result = {}
        self.responses.append(json.dumps({'id': request['id'], 'result': result}))

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self.responses:
            raise StopAsyncIteration
        return self.responses.pop(0)


class BackendContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_idle_root_with_no_children_is_inspected_without_resume(self):
        socket = FixtureSocket()
        result = await module.Backend(socket).inspect('old-1', '/project')
        self.assertTrue(result['idle'])
        self.assertTrue(result['no_descendants'])
        self.assertNotIn('thread/resume', [x['method'] for x in socket.calls])

    async def test_active_source_is_refused_before_any_lifecycle_write(self):
        socket = FixtureSocket(active=True)
        with self.assertRaises(ValueError):
            await module.Backend(socket).inspect('old-1', '/project')
        self.assertNotIn('thread/start', [x['method'] for x in socket.calls])

    async def test_child_scope_is_refused(self):
        with self.assertRaises(ValueError):
            await module.Backend(FixtureSocket(children=True)).inspect('old-1', '/project')

    async def test_lost_rpc_response_is_not_retried(self):
        socket = FixtureSocket(lost=True)
        with self.assertRaises(ConnectionError):
            await module.Backend(socket).rpc('thread/start', {'cwd': '/project'})
        self.assertEqual(len(socket.calls), 1)

    async def test_changed_capsule_hash_cannot_resume_or_load_destination(self):
        socket = FixtureSocket()
        with self.assertRaises(ValueError):
            await module.Backend(socket).load('new-1', {'capsule': '{}', 'sha256': 'wrong', 'cwd': '/project'})
        self.assertEqual(socket.calls, [])


if __name__ == '__main__':
    unittest.main()
