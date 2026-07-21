"""Unit tests for the robust/efficient TCP transport client.

Each test drives the client against a real loopback server on an ephemeral port,
so the auto-reconnect, framing, liveness-watchdog and disconnected-send paths are
exercised end to end rather than mocked.
"""

import json
import socket
import sys
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from windows.transport.tcp_client import TCPTransportClient, ConnectionState


def wait_until(predicate, timeout: float = 3.0, interval: float = 0.02) -> bool:
    """Poll ``predicate`` until true or the timeout elapses."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return bool(predicate())


class _LoopbackServer:
    """Minimal newline-delimited JSON server mimicking TransportServerService."""

    def __init__(self, reply_to_ping: bool = True):
        self.reply_to_ping = reply_to_ping
        self.received = []
        self.clients = []
        self._running = True
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(5)
        self.port = self._sock.getsockname()[1]
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def _accept_loop(self):
        while self._running:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                break
            self.clients.append(conn)
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        # The real server emits an initial heartbeat the moment a client connects.
        self._send(conn, {"version": "1.0", "type": "heartbeat", "status": "ready"})
        conn.settimeout(0.25)
        buffer = b""
        while self._running:
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                msg = json.loads(line.decode("utf-8"))
                self.received.append(msg)
                if msg.get("command") == "ping" and self.reply_to_ping:
                    self._send(conn, {"type": "heartbeat", "status": "ready"})

    @staticmethod
    def _send(conn, payload):
        try:
            conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        except OSError:
            pass

    def drop_clients(self):
        for conn in list(self.clients):
            try:
                conn.close()
            except OSError:
                pass
        self.clients.clear()

    def close(self):
        self._running = False
        try:
            self._sock.close()
        except OSError:
            pass
        self.drop_clients()


class TestTCPTransportClient(unittest.TestCase):
    def _client(self, server_port, **overrides):
        params = dict(
            host="127.0.0.1",
            port=server_port,
            initial_backoff=0.05,
            max_backoff=0.2,
            enable_heartbeat=False,
        )
        params.update(overrides)
        client = TCPTransportClient(**params)
        self.addCleanup(client.stop)
        return client

    def test_connects_sends_and_receives(self):
        server = _LoopbackServer()
        self.addCleanup(server.close)
        received, states = [], []
        client = self._client(
            server.port,
            on_message_callback=received.append,
            on_state_change=states.append,
        )
        client.start()

        self.assertTrue(wait_until(lambda: client.is_connected), "client did not connect")
        self.assertIn(ConnectionState.CONNECTED, states)
        self.assertTrue(
            wait_until(lambda: any(m.get("type") == "heartbeat" for m in received)),
            "did not receive the initial heartbeat",
        )

        self.assertTrue(client.send_json({"type": "command", "command": "start_listening"}))
        self.assertTrue(
            wait_until(lambda: any(m.get("command") == "start_listening" for m in server.received)),
            "server never received the dispatched command",
        )

    def test_reconnects_after_server_drops_client(self):
        server = _LoopbackServer()
        self.addCleanup(server.close)
        client = self._client(server.port)
        client.start()
        self.assertTrue(wait_until(lambda: client.is_connected), "initial connect failed")

        server.drop_clients()
        self.assertTrue(wait_until(lambda: not client.is_connected, timeout=3.0), "drop not detected")
        # The auto-reconnect loop must recover on its own.
        self.assertTrue(wait_until(lambda: client.is_connected, timeout=5.0), "did not auto-reconnect")

    def test_send_while_disconnected_returns_false(self):
        # Port 1 is not listening: connect never succeeds, so a send must fail cleanly.
        client = self._client(1, auto_reconnect=False)
        self.assertFalse(client.send_json({"type": "command", "command": "ping"}))

    def test_heartbeat_watchdog_drops_silent_link(self):
        server = _LoopbackServer(reply_to_ping=False)
        self.addCleanup(server.close)
        client = self._client(
            server.port,
            auto_reconnect=False,      # stay down once dropped so the assertion is stable
            enable_heartbeat=True,
            heartbeat_interval=0.1,
            heartbeat_timeout=0.4,
        )
        client.start()  # synchronous connect (auto_reconnect disabled)
        self.assertTrue(client.is_connected, "synchronous connect failed")
        # No heartbeat reply ever arrives, so the watchdog must tear the link down.
        self.assertTrue(
            wait_until(lambda: not client.is_connected, timeout=3.0),
            "watchdog did not drop the silent link",
        )


if __name__ == "__main__":
    unittest.main()
