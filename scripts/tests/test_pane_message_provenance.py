import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pane_messaging', ROOT / 'Sources/Relay/Resources/Rotation/pane_messaging.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Provenance(unittest.TestCase):
    def setUp(self):
        self.source = {'hostID': 'claimed-host', 'paneID': 'claimed-pane', 'sessionID': 'trusted-peer-session'}
        self.packet = {'source': self.source, 'targetPaneID': 'recipient', 'messageID': 'message-id',
                       'text': 'fixture', 'submittingClientID': 'server-resolved-client'}
        self.endpoint = {'socketPath': '/fixture.sock', 'socketIdentity': 'fixture', 'socketPID': 17,
                         'socketStart': 'start', 'sessionID': 'recipient-thread'}

    def test_claude_headers_do_not_impersonate_claimed_source(self):
        self.endpoint['transport'] = 'native_peer_socket'
        client = Mock()
        factory = Mock()
        factory.return_value.__enter__ = Mock(return_value=client)
        factory.return_value.__exit__ = Mock(return_value=False)
        with patch.object(m, 'private_json', return_value={'peerToken': 'fixture-token'}), \
             patch.object(m, 'socket_identity', return_value='fixture'), \
             patch.object(m.socket, 'socket', factory):
            result = m.deliver({'identity': lambda pid: 'start'}, self.endpoint, self.packet)
        frames = [json.loads(line) for line in client.sendall.call_args[0][0].decode().splitlines()]
        frame = frames[1]
        self.assertEqual(frame['from'], 'relay-unverified-submission://message-id')
        body = frame['message']['content']
        self.assertIn('from-session=""', body)
        self.assertIn('from-name="Unauthenticated Relay submission"', body)
        self.assertNotIn('trusted-peer-session', body)
        self.assertIn('server-resolved-client', body)
        self.assertIn('not verified authorship', body)
        self.assertEqual(result['status'], 'written_to_socket')

    def test_codex_claim_is_provenance_not_sender(self):
        self.endpoint['transport'] = 'codex_app_server_message'
        client = Mock()
        client.rpc.return_value = {'turn': {'id': 'turn-id'}}
        with patch.object(m, 'UnixWebSocket', return_value=client):
            result = m.deliver({}, self.endpoint, self.packet)
        method, args = client.rpc.call_args[0]
        envelope = json.loads(args['toolOutput']['output'])
        self.assertEqual(envelope['sender'], {'kind': 'unauthenticated_relay_submission'})
        self.assertEqual(envelope['provenance']['claimedSource'], self.source)
        self.assertEqual(envelope['provenance']['registeredClientID'], 'server-resolved-client')
        self.assertEqual(envelope['provenance']['desktopThreadAuthentication'], 'unverified')
        self.assertEqual(args['input'], [])
        self.assertEqual(args['toolOutput']['name'], 'peer_message')
        self.assertEqual(result['status'], 'accepted_by_provider')
        client.close.assert_called_once()

    def test_missing_client_is_legacy_unattributed(self):
        self.packet.pop('submittingClientID')
        self.endpoint['transport'] = 'codex_app_server_message'
        client = Mock()
        client.rpc.return_value = {'turn': {'id': 'turn-id'}}
        with patch.object(m, 'UnixWebSocket', return_value=client):
            m.deliver({}, self.endpoint, self.packet)
        envelope = json.loads(client.rpc.call_args[0][1]['toolOutput']['output'])
        self.assertEqual(envelope['provenance']['registeredClientID'], 'legacy-unattributed')
        self.assertEqual(envelope['provenance']['authentication'], 'unverified')

if __name__ == '__main__':
    unittest.main()
