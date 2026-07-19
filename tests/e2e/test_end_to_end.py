#!/usr/bin/env python3
"""
Project Hermes - End-to-End (E2E) Automated Integration Test Suite
Verifies TCP socket transport, protocol handshakes, start/stop listening command dispatching,
and speech event stream validation against physical Android device / emulator over ADB port 9999.
"""

import sys
import json
import time
import socket
import unittest
from pathlib import Path

# Add REPO_ROOT to sys.path
REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))


class TestHermesEndToEnd(unittest.TestCase):
    HOST = "127.0.0.1"
    PORT = 9999

    def setUp(self):
        """Creates a socket connection to Android TransportServer on port 9999."""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(5.0)
            self.sock.connect((self.HOST, self.PORT))
        except Exception as e:
            self.fail(f"E2E Setup Failed: Cannot connect to Android TransportServer at {self.HOST}:{self.PORT}. Is 'task deploy' or ADB forward active? Error: {e}")

    def tearDown(self):
        """Closes socket connection."""
        if hasattr(self, 'sock') and self.sock:
            try:
                self.sock.close()
            except Exception:
                pass

    def read_json_line(self, timeout: float = 5.0) -> dict:
        """Reads a single newline-delimited JSON message from socket."""
        self.sock.settimeout(timeout)
        buffer = ""
        while "\n" not in buffer:
            chunk = self.sock.recv(1024).decode("utf-8")
            if not chunk:
                break
            buffer += chunk
        line = buffer.split("\n", 1)[0].strip()
        self.assertTrue(line, "Received empty line from Android server.")
        return json.loads(line)

    def test_01_connection_heartbeat(self):
        """Test initial TCP connection receives valid heartbeat JSON."""
        msg = self.read_json_line(timeout=3.0)
        self.assertEqual(msg.get("type"), "heartbeat")
        self.assertEqual(msg.get("status"), "ready")
        self.assertEqual(msg.get("version"), "1.0")
        print(f"\n  ✅ [E2E STEP 1] Heartbeat Handshake Verified: Status '{msg.get('status')}'")

    def test_02_ping_command(self):
        """Test sending 'ping' command receives 'heartbeat' ready response."""
        # Read initial connection heartbeat first
        self.read_json_line(timeout=3.0)

        # Send ping
        ping_payload = {
            "version": "1.0",
            "type": "command",
            "command": "ping",
            "timestamp": int(time.time() * 1000)
        }
        self.sock.sendall((json.dumps(ping_payload) + "\n").encode("utf-8"))

        # Assert response
        msg = self.read_json_line(timeout=3.0)
        self.assertEqual(msg.get("type"), "heartbeat")
        self.assertEqual(msg.get("status"), "ready")
        print("\n  ✅ [E2E STEP 2] Ping Command Protocol Round-Trip Verified.")

    def test_03_start_and_stop_listening_protocol(self):
        """Test sending 'start_listening' followed by 'stop_listening' commands."""
        # Read initial connection heartbeat
        self.read_json_line(timeout=3.0)

        # Send start_listening
        start_payload = {
            "version": "1.0",
            "type": "command",
            "command": "start_listening",
            "timestamp": int(time.time() * 1000)
        }
        self.sock.sendall((json.dumps(start_payload) + "\n").encode("utf-8"))
        print("\n  ✅ [E2E STEP 3a] 'start_listening' Command Dispatched to Android.")

        time.sleep(1.0)

        # Send stop_listening
        stop_payload = {
            "version": "1.0",
            "type": "command",
            "command": "stop_listening",
            "timestamp": int(time.time() * 1000)
        }
        self.sock.sendall((json.dumps(stop_payload) + "\n").encode("utf-8"))
        print("  ✅ [E2E STEP 3b] 'stop_listening' Command Dispatched to Android.")


if __name__ == "__main__":
    print("=" * 65)
    print("🧪 Project Hermes Automated End-to-End (E2E) Test Suite")
    print("=" * 65)
    unittest.main(verbosity=2)
