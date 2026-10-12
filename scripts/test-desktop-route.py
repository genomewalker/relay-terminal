import importlib.util
import json
import os
import sys
from pathlib import Path
import socket
import tempfile
import unittest
import asyncio
import uuid
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('route', ROOT / 'relay-desktop-route.py')
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)
remote_spec = importlib.util.spec_from_file_location('remote', ROOT / 'relay-desktop-remote.py')
remote = importlib.util.module_from_spec(remote_spec)
remote_spec.loader.exec_module(remote)


class RouteTests(unittest.TestCase):
    def test_task_picker_only_lists_loaded_tasks(self):
        class Connection:
            def __init__(self):
                self.calls = []
                self.reply = None
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            async def send(self, raw):
                request = json.loads(raw)
                self.calls.append(request['method'])
                self.reply = json.dumps(dict(id=request['id'], result={} if request['id'] == 1 else dict(data=['b', 'a'])))
            def __aiter__(self): return self
            async def __anext__(self):
                if self.reply is None: raise StopAsyncIteration
                result, self.reply = self.reply, None
                return result
        connection = Connection()
        with patch.object(route.ingress, 'check_socket'), \
             patch.object(route.ingress.websockets, 'unix_connect', return_value=connection):
            self.assertEqual(asyncio.run(route.ingress.loaded_tasks('/private/socket')), ['a', 'b'])
        self.assertEqual(connection.calls, ['initialize', 'thread/loaded/list'])

    def test_network_task_details_use_loaded_names_and_status_without_turns(self):
        class Connection:
            def __init__(self):
                self.calls = []
                self.reply = None
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            async def send(self, raw):
                request = json.loads(raw)
                self.calls.append(request)
                method = request['method']
                if method == 'initialize': result = {}
                elif method == 'thread/loaded/list': result = dict(data=['task-b', 'task-a'])
                else:
                    thread = request['params']['threadId']
                    result = dict(thread=dict(id=thread, name='Review network',
                                              status=dict(type='active' if thread == 'task-a' else 'idle')))
                self.reply = json.dumps(dict(id=request['id'], result=result))
            def __aiter__(self): return self
            async def __anext__(self):
                if self.reply is None: raise StopAsyncIteration
                result, self.reply = self.reply, None
                return result
        connection = Connection()
        with patch.object(route.ingress, 'check_socket'), \
             patch.object(route.ingress.websockets, 'unix_connect', return_value=connection):
            details = asyncio.run(route.ingress.loaded_task_details('/private/socket'))
        self.assertEqual([x['id'] for x in details], ['task-a', 'task-b'])
        self.assertEqual([x['status'] for x in details], ['active', 'idle'])
        self.assertEqual([x['name'] for x in details], ['Review network', 'Review network'])
        self.assertTrue(all(c['params']['includeTurns'] is False for c in connection.calls[2:]))

    def test_reply_address_stable_and_single_owner(self):
        name = 'test-' + uuid.uuid4().hex
        with remote.mailbox_directory(name) as first:
            with self.assertRaises(BlockingIOError):
                with remote.mailbox_directory(name):
                    self.fail('duplicate owner')
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(first + '/peer.sock')
        self.assertFalse(Path(first + '/peer.sock').exists())
        with remote.mailbox_directory(name) as second:
            self.assertEqual(first, second)
        Path(first + '/lock').unlink()
        Path(first).rmdir()

    def test_remember_is_per_task_idempotent_and_refuses_rebind(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home/'.local/share/relay/desktop-routing').mkdir(parents=True)
            a = route.remember(self.config(), home)
            self.assertEqual(a, route.remember(self.config(), home))
            other = dict(self.config(), thread='another-task')
            b = route.remember(other, home)
            self.assertNotEqual(a['replyName'], b['replyName'])
            self.assertNotEqual(a['service'], b['service'])
            with self.assertRaisesRegex(ValueError, 'rebind'):
                route.remember(dict(self.config(), remotePID=2), home)

    def test_explicit_rebind_only_replaces_remote_incarnation(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home/'.local/share/relay/desktop-routing').mkdir(parents=True)
            saved = route.remember(self.config(), home)
            replacement = dict(self.config(), remotePID=2, remoteStart='456', remoteName='renamed')
            self.assertEqual(route.remember(replacement, home, rebind=True), saved)
            self.assertEqual(route.read_private(Path(saved['config']))['remotePID'], 2)
            for changed in (dict(replacement, thread='other-task'),
                            dict(replacement, socket='/tmp/different.sock')):
                with self.assertRaisesRegex(ValueError, 'rebind'):
                    route.remember(changed, home, rebind=True)

    def test_connection_registry_tracks_explicit_task_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            root = home/'.local/share/relay/desktop-routing'
            root.mkdir(parents=True)
            saved = route.remember(self.config(), home)
            path = Path(saved['config'])
            self.assertEqual(route.service_for_config(path, home)[0], saved['label'])
            updated = route.handoff(path, 'followup', home)
            self.assertEqual(updated['localName'], saved['replyName'])
            self.assertEqual(updated['thread'], 'followup')
            self.assertEqual(route.read_private(path)['thread'], 'followup')
            record = route.connection_registry(root)[0]
            self.assertEqual(record['tasks'], ['local', 'followup'])
            self.assertEqual(record['currentTask'], 'followup')
            current = dict(self.config(), thread='followup')
            self.assertEqual(route.remember(current, home)['replyName'], saved['replyName'])
            self.assertEqual(len([p for p in root.glob('*.json') if p.name != 'connections.json']), 1)
            with self.assertRaisesRegex(ValueError, 'different desktop task'):
                route.handoff(path, 'followup', home)

    def test_reconnect_backoff_is_bounded_indefinitely(self):
        self.assertEqual([route.reconnect_delay(n) for n in range(7)], [1, 2, 4, 8, 16, 30, 30])
        self.assertEqual(route.reconnect_delay(100000), 30)

    def test_supervisor_survives_more_than_six_disconnects(self):
        class Worker:
            returncode = 0
            def __init__(self):
                self.stdout = asyncio.StreamReader()
                self.stdout.feed_eof()
        async def exercise(tmp):
            starts = []
            async def spawn(*args, **kwargs):
                starts.append(args)
                return Worker()
            async def sleep(delay):
                if len(starts) == 9:
                    raise asyncio.CancelledError()
            with patch.object(route.Path, 'home', return_value=Path(tmp)), \
                 patch.object(route.ingress, 'verify_loaded_task', AsyncMock()), \
                 patch.object(route.asyncio, 'create_subprocess_exec', side_effect=spawn), \
                 patch.object(route.asyncio, 'sleep', side_effect=sleep):
                with self.assertRaises(asyncio.CancelledError):
                    await route.run(self.config(), Path(tmp)/'route.json', 'listen')
            self.assertEqual(len(starts), 9)
        with tempfile.TemporaryDirectory() as tmp:
            asyncio.run(exercise(tmp))

    def test_identity_change_stops_without_rebinding(self):
        async def exercise(tmp):
            class Worker:
                returncode = 3
                def __init__(self):
                    self.stdout = asyncio.StreamReader()
                    self.stdout.feed_data(b'{"type":"identity_changed"}\n')
                    self.stdout.feed_eof()
            async def spawn(*args, **kwargs):
                return Worker()
            with patch.object(route.Path, 'home', return_value=Path(tmp)), \
                 patch.object(route.ingress, 'verify_loaded_task', AsyncMock()), \
                 patch.object(route.asyncio, 'create_subprocess_exec', side_effect=spawn) as mock:
                await route.run(self.config(), Path(tmp)/'route.json', 'listen')
                self.assertEqual(mock.call_count, 1)
            state = route.read_private(Path(tmp)/'.local/state/relay/peer-network/reply.json')
            self.assertEqual(state['state'], 'needs_attention')
            self.assertTrue(state['rebindRequired'])
            self.assertNotIn('mailbox', state)
        with tempfile.TemporaryDirectory() as tmp:
            asyncio.run(exercise(tmp))

    def test_missing_remote_endpoint_requires_rebind(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(remote.IdentityChanged, 'explicit rebinding'):
                remote.endpoint(Path(tmp), 1424257, 'session', '123')

    def test_same_session_replacement_is_unique_and_live(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp)
            sockets = []
            try:
                for pid in (42, 43):
                    sock = socket.socket(socket.AF_UNIX)
                    sock.bind(str(registry / ('%d.sock' % pid)))
                    sockets.append(sock)
                    (registry / ('%d.json' % pid)).write_text(json.dumps(dict(
                        pid=pid, sessionId='same', procStart='123', name='peer-%d' % pid,
                        messagingSocketPath=str(registry / ('%d.sock' % pid)))))
                with patch.object(remote, 'start', return_value='123'):
                    self.assertRaisesRegex(remote.IdentityChanged, 'multiple live',
                                           remote.replacement_for_session, registry, 'same')
                    (registry / '43.json').unlink()
                    self.assertEqual(remote.replacement_for_session(registry, 'same'),
                                     dict(pid=42, start='123', name='peer-42'))
                    self.assertIsNone(remote.replacement_for_session(registry, 'different'))
            finally:
                for sock in sockets: sock.close()

    def test_auto_recovery_updates_only_remote_incarnation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'route.json'
            c = self.config()
            route.write(path, c)
            route.adopt_same_session(c, path, dict(session='remote', pid=2, start='456', name='new'))
            self.assertEqual((c['remotePID'], c['remoteStart'], c['remoteName']), (2, '456', 'new'))
            self.assertEqual(route.read_private(path), c)
            with self.assertRaises(route.RebindRequired):
                route.adopt_same_session(c, path, dict(session='other', pid=3, start='789', name='other'))

    def test_supervisor_restarts_with_verified_same_session_replacement(self):
        async def exercise(tmp):
            path = Path(tmp) / 'route.json'
            route.write(path, self.config())
            starts = []
            class Worker:
                returncode = 3
                def __init__(self):
                    self.stdout = asyncio.StreamReader()
                    self.stdout.feed_data(json.dumps(dict(type='identity_replacement',
                        session='remote', pid=2, start='456', name='new')).encode() + b'\n')
                    self.stdout.feed_eof()
            async def spawn(*args, **kwargs):
                starts.append(args)
                if len(starts) == 2: raise asyncio.CancelledError()
                return Worker()
            with patch.object(route.Path, 'home', return_value=Path(tmp)), \
                 patch.object(route.ingress, 'verify_loaded_task', AsyncMock()), \
                 patch.object(route.asyncio, 'create_subprocess_exec', side_effect=spawn):
                with self.assertRaises(asyncio.CancelledError):
                    await route.run(self.config(), path, 'listen')
            self.assertEqual(len(starts), 2)
            self.assertEqual(starts[1][-5:], ('listen', '2', 'remote', '456', 'reply'))
            self.assertEqual(route.read_private(path)['remotePID'], 2)
        with tempfile.TemporaryDirectory() as tmp:
            asyncio.run(exercise(tmp))

    def config(self):
        return dict(host='dandy-07', localName='reply', remoteName='codex-1',
                    remoteSession='remote', thread='local', remotePID=1,
                    remoteStart='123', socket='/tmp/private.sock')

    def test_invalid_configuration(self):
        route.validate_config(self.config())
        for key, value in [('host', '-oProxyCommand=bad'), ('remotePID', True),
                           ('remotePID', 0), ('remoteStart', 'abc'),
                           ('socket', 'relative'), ('remoteName', '../peer')]:
            c = self.config()
            c[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                route.validate_config(c)

    def test_live_route_exact_binding_and_freshness(self):
        c = self.config()
        state = dict(host=c['host'], localName=c['localName'], localSession=c['thread'],
                     remoteSession=c['remoteSession'], remotePID=1, remoteStart='123',
                     state='online', heartbeatEpoch=100, mailbox=dict(pid=2, start='456'))
        self.assertEqual(route.validate_live_route(c, state, 110)['pid'], 2)
        for key, value in [('host', 'other'), ('remotePID', 3), ('remoteStart', '124'),
                           ('localName', 'other'), ('state', 'offline'),
                           ('heartbeatEpoch', 111), ('heartbeatEpoch', 84),
                           ('heartbeatEpoch', float('nan')), ('mailbox', {})]:
            broken = dict(state, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                route.validate_live_route(c, broken, 110)

    def test_collaborator_authority(self):
        p = route.ingress.params('task', dict(id='1', sender='peer', content='hello'))
        self.assertEqual(p['input'], [])
        self.assertEqual(p['toolOutput']['namespace'], 'relay')
        self.assertEqual(json.loads(p['toolOutput']['output'])['sender'], 'peer')

    def test_message_validation(self):
        for message in (None, {}, dict(id='1', sender='', content='x'),
                        dict(id='1', sender='peer', content='x'*65536)):
            with self.assertRaises(ValueError):
                route.ingress.params('task', message)

    def test_read_receipt_requires_exact_recipient_ack_and_known_message(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'route.json'
            message = 'relay-test-123'
            self.assertTrue(route.update_read_receipt(config, message, 'pending', create=True))
            self.assertIsNone(route.read_acknowledgment('I saw Relay-Read-Receipt: ' + message))
            self.assertEqual(route.read_acknowledgment(
                '<cross-session-message from="uds:/safe">\nRelay-Read-Receipt: '
                + message + '\n</cross-session-message>'), message)
            self.assertFalse(route.update_read_receipt(config, 'unknown-id', 'read_acknowledged'))
            self.assertTrue(route.update_read_receipt(config, message, 'read_acknowledged'))
            route.update_read_receipt(config, message, 'written_to_socket')
            values = route.read_private(route.receipt_file(config))
            self.assertEqual(values[0]['status'], 'read_acknowledged')
            with self.assertRaises(ValueError):
                route.update_read_receipt(config, message, 'pending', create=True)

    def test_socket_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = str(Path(tmp)/'s')
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(p)
                os.chmod(p, 0o600)
                route.ingress.check_socket(p)
                os.chmod(p, 0o666)
                with self.assertRaises(ValueError):
                    route.ingress.check_socket(p)

    def test_private_desktop_socket_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            link_dir, target_dir = root/'link', root/'target'
            link_dir.mkdir(mode=0o700)
            target_dir.mkdir(mode=0o700)
            target = target_dir/'server.sock'
            link = link_dir/'current.sock'
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(target))
                os.chmod(target, 0o600)
                link.symlink_to(target)
                self.assertEqual(route.ingress.check_socket(str(link)), str(target))
                os.chmod(target_dir, 0o755)
                with self.assertRaisesRegex(ValueError, 'unsafe desktop socket directory'):
                    route.ingress.check_socket(str(link))

    def test_private_atomic_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'status'
            route.write(p, dict(state='online'))
            self.assertEqual(route.read_private(p)['state'], 'online')
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            os.chmod(p, 0o644)
            with self.assertRaises(ValueError):
                route.read_private(p)

    def test_host_transport_uses_structured_argv_and_receipt_checkpoints(self):
        c = dict(host='dandy-07',remotePID=1,remoteSession='s',remoteStart='123',localName='reply')
        cmd = route.command(c, 'listen')
        self.assertEqual(cmd[:5], [sys.executable, str(route.ROOT / 'relay-host-process.py'),
                                  'dandy-07', 'listen', '--receipt-checkpoints'])
        self.assertEqual(cmd[-5:], ['listen', '1', 's', '123', 'reply'])
        self.assertEqual(cmd[5:8], ['python3', '-u', '-c'])
        self.assertNotIn('--receipt-checkpoints', route.command(c, 'send'))


if __name__ == '__main__':
    unittest.main()
