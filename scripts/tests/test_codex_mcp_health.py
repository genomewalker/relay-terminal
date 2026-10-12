import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('mcp_health', Path(__file__).parents[1] / 'relay-codex-mcp-health.py')
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class HealthProtocolTests(unittest.TestCase):
    def fixture(self, callback, bad_accept=False):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        path = str(Path(root.name) / 'control.sock')
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(1)
        errors = []

        def serve():
            try:
                with listener:
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(3)
                        request = b''
                        while b'\r\n\r\n' not in request:
                            request += conn.recv(4096)
                        key = next(line.split(b':', 1)[1].strip() for line in request.split(b'\r\n') if line.startswith(b'Sec-WebSocket-Key:'))
                        accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                        conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + (b'wrong' if bad_accept else accept) + b'\r\n\r\n')
                        if not bad_accept:
                            callback(conn)
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=serve)
        worker.start()

        def finish():
            worker.join(4)
            self.assertFalse(worker.is_alive())
            if errors:
                raise errors[0]
        self.addCleanup(finish)
        return path

    @staticmethod
    def read_frame(conn):
        def exact(n):
            result = b''
            while len(result) < n:
                result += conn.recv(n - len(result))
            return result
        first, size = exact(2)
        assert size & 128
        size &= 127
        assert size < 126
        mask = exact(4)
        data = exact(size)
        return first & 15, bytes(b ^ mask[i % 4] for i, b in enumerate(data))

    def test_masked_request_fragmented_response_and_ping(self):
        def server(conn):
            opcode, data = self.read_frame(conn)
            self.assertEqual(opcode, 1)
            request = json.loads(data)
            self.assertEqual(request['method'], 'inspect')
            conn.sendall(b'\x89\x01p')
            self.assertEqual(self.read_frame(conn), (10, b'p'))
            response = json.dumps({'id': request['id'], 'result': {'healthy': True}}).encode()
            conn.sendall(bytes([1, 5]) + response[:5] + bytes([128, len(response) - 5]) + response[5:])
        connection = health.Connection(self.fixture(server))
        try:
            self.assertEqual(connection.rpc('inspect', {}), {'healthy': True})
        finally:
            connection.sock.close()

    def test_rejects_incorrect_handshake(self):
        with self.assertRaises(ConnectionError):
            health.Connection(self.fixture(lambda _: None, bad_accept=True))

    def test_rejects_masked_server_frame(self):
        connection = health.Connection(self.fixture(lambda c: c.sendall(b'\x81\x80')))
        try:
            with self.assertRaises(ValueError):
                connection.receive()
        finally:
            connection.sock.close()


if __name__ == '__main__':
    unittest.main()
