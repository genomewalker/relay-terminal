import asyncio
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import uuid
import json

spec = importlib.util.spec_from_file_location('group', Path(__file__).with_name('relay-desktop-group.py'))
group = importlib.util.module_from_spec(spec)
spec.loader.exec_module(group)


class GroupTests(unittest.TestCase):
    def test_missing_autonomous_task_has_no_side_effects(self):
        plan = self.plan()
        plan.update(autonomous=True, purpose=' ')
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(group.route.ingress, 'loaded_tasks', AsyncMock()) as loaded:
                with self.assertRaises(ValueError): asyncio.run(group.apply(plan, Path(tmp)/'receipts'))
                loaded.assert_not_called()
            self.assertEqual(list(Path(tmp).iterdir()), [])
    def plan(self):
        return dict(id=str(uuid.uuid4()), topology='coordinator', coordinatorID='desktop:laptop:task', purpose='Review',
                    participants=[dict(kind='desktop', host='laptop', session='task', name='task'),
                                  dict(kind='native', host='dandy-07', session='remote', name='peer', pid=1, processStart='123'),
                                  dict(kind='native', host='dandy-08', session='remote2', name='peer2', pid=2, processStart='456')])

    def test_star_pins_each_remote(self):
        edges = group.pairs(self.plan())
        self.assertEqual(len(edges), 2)
        self.assertEqual([c['remoteStart'] for _, _, c in edges], ['123', '456'])

    def test_unsupported_mesh_has_no_side_effects(self):
        plan = self.plan()
        plan['topology'] = 'everyone'
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                asyncio.run(group.apply(plan, Path(tmp)/'receipts'))
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_duplicate_group_cannot_resend(self):
        plan = self.plan()
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            group.route.write(directory/(plan['id']+'.json'), dict(state='unknown'))
            with patch.object(group.route.ingress, 'loaded_tasks', AsyncMock(return_value=['task'])), \
                 patch.object(group.route, 'remember') as remember:
                with self.assertRaises(FileExistsError):
                    asyncio.run(group.apply(plan, directory))
                remember.assert_not_called()

    def test_closed_desktop_task_does_not_create_routes(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(group.route.ingress, 'loaded_tasks', AsyncMock(return_value=[])), \
                 patch.object(group.route, 'remember') as remember:
                with self.assertRaises(ValueError):
                    asyncio.run(group.apply(self.plan(), Path(tmp)/'receipts'))
                remember.assert_not_called()

    def test_failed_route_sends_no_introductions_and_keeps_receipt(self):
        plan = self.plan()
        process = AsyncMock()
        process.returncode = 1
        process.communicate.return_value = (b'', b'')
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(group.route.ingress, 'loaded_tasks', AsyncMock(return_value=['task'])), \
                 patch.object(group.route, 'remember', return_value={'config': '/unused'}), \
                 patch.object(group.asyncio, 'create_subprocess_exec', AsyncMock(return_value=process)), \
                 patch.object(group.route.ingress, 'deliver', AsyncMock()) as deliver:
                result = asyncio.run(group.apply(plan, Path(tmp)))
                self.assertEqual(result['state'], 'needs_attention')
                self.assertEqual(result['introductions'], [])
                deliver.assert_not_called()
                self.assertEqual(json.loads((Path(tmp)/(plan['id']+'.json')).read_text()), result)

    def test_receipt_replace_remains_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'receipt.json'
            group.save_receipt(path, {'receipt': 'unknown'})
            group.save_receipt(path, {'receipt': 'socket_written'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())['receipt'], 'socket_written')
            self.assertEqual(len(list(Path(tmp).iterdir())), 1)


class DesktopTests(unittest.IsolatedAsyncioTestCase):
    async def test_socket_delivery_both_directions_and_closed_task(self):
        import os
        import websockets
        with tempfile.TemporaryDirectory() as tmp:
            socket = str(Path(tmp)/'desktop.sock')
            received = []
            loaded = ['a', 'b', 'c']
            async def handler(ws):
                async for raw in ws:
                    request = json.loads(raw)
                    method = request['method']
                    result = {}
                    if method == 'thread/loaded/list': result = {'data': loaded}
                    if method == 'turn/start':
                        received.append(request['params'])
                        result = {'turn': {'id': 'turn-'+str(len(received))}}
                    await ws.send(json.dumps({'id': request['id'], 'result': result}))
            async with websockets.unix_serve(handler, socket):
                os.chmod(socket, 0o600)
                plan = dict(id=str(uuid.uuid4()), topology='coordinator',
                            coordinatorID='desktop:laptop:a', purpose='Review',
                            participants=[dict(kind='desktop', host='laptop', session=x, name=x)
                                          for x in loaded])
                directory = Path(tmp)/'receipts'
                with patch.object(group.Path, 'home', return_value=Path(tmp)):
                    # Use the real ingress on a private Unix websocket.
                    original = group.route.ingress.loaded_tasks
                    async def discovery(_): return await original(socket)
                    original_deliver = group.route.ingress.deliver
                    async def delivery(_, thread, envelope):
                        return await original_deliver(socket, thread, envelope)
                    with patch.object(group.route.ingress, 'loaded_tasks', discovery), \
                         patch.object(group.route.ingress, 'deliver', delivery):
                        result = await group.apply(plan, directory)
                        self.assertEqual(result['state'], 'introductions_attempted')
                        receipt = directory/(plan['id']+'.json')
                        for a, b in [('a', 'b'), ('b', 'a')]:
                            sent = await group.send_desktop(receipt, a, b, 'hello '+b)
                            self.assertEqual(sent['receipt'], 'admitted')
                            self.assertEqual(received[-1]['threadId'], b)
                            self.assertEqual(received[-1]['input'], [])
                            envelope = json.loads(received[-1]['toolOutput']['output'])
                            self.assertEqual(envelope['sender'], 'Relay desktop task '+a)
                        with self.assertRaises(ValueError):
                            await group.send_desktop(receipt, 'b', 'c', 'not a star edge')
                        loaded.remove('b')
                        count = len(received)
                        with self.assertRaises(ValueError):
                            await group.send_desktop(receipt, 'a', 'b', 'closed')
                        self.assertEqual(len(received), count)
                        with self.assertRaises(ValueError):
                            await group.apply(plan, directory)
                        loaded.append('b')
                        with self.assertRaises(FileExistsError):
                            await group.apply(plan, directory)
                        self.assertEqual(len(received), count)

    async def test_failed_introduction_keeps_unknown_receipt(self):
        plan = dict(id=str(uuid.uuid4()), topology='everyone', purpose='',
                    participants=[dict(kind='desktop', host='laptop', session=x, name=x) for x in ['a','b']])
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(group.route.ingress, 'loaded_tasks', AsyncMock(return_value=['a','b'])), \
                 patch.object(group.route.ingress, 'deliver', AsyncMock(return_value={'receipt':'unknown'})) as deliver:
                result = await group.apply(plan, Path(tmp))
                self.assertEqual(result['state'], 'needs_attention')
                self.assertEqual(result['introductions'][0]['receipt'], 'unknown')
                self.assertEqual(deliver.await_count, 1)

    def test_mesh_and_invalid_endpoints(self):
        plan = dict(topology='everyone', participants=[dict(kind='desktop', host='laptop', session=x, name=x) for x in ['a','b','c']])
        self.assertEqual(len(group.desktop_edges(plan)), 3)
        plan['participants'][0]['host'] = 'remote'
        with self.assertRaises(ValueError): group.desktop_edges(plan)


if __name__ == '__main__': unittest.main()
