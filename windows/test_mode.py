#!/usr/bin/env python3
"""
Test Mode CLI & Simulator - Project Hermes (REQ-FUNC-011)
Simulates speech recognition events, mock Android socket responses, and test payload playback.
"""

import argparse
import json
import socket
import sys
import time
import logging
from pathlib import Path

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from windows.injector.text_injector import TextInjector

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] (%(name)s) %(message)s"
)
logger = logging.getLogger("HermesTestMode")


class TestModeSimulator:
    def __init__(self, host: str = "127.0.0.1", port: int = 9999):
        self.host = host
        self.port = port
        self.injector = TextInjector()

    def run_interactive(self):
        print("\n" + "=" * 60)
        print("🎙️ Project Hermes Test Mode - Interactive Speech Simulator")
        print("=" * 60)
        print("Instructions:")
        print("  1. Focus the window where you want text injected (e.g. VS Code, Notepad).")
        print("  2. Type a sentence below and press Enter.")
        print("  3. Simulator will stream partial text, then inject the final result.")
        print("  4. Type 'exit' or 'quit' to stop.\n")

        while True:
            try:
                prompt = input("Enter speech text to simulate > ").strip()
                if not prompt:
                    continue
                if prompt.lower() in ["exit", "quit"]:
                    print("Exiting interactive test mode.")
                    break

                self.simulate_speech_stream(prompt)
            except (KeyboardInterrupt, EOFError):
                print("\nExiting interactive test mode.")
                break

    def simulate_speech_stream(self, text: str):
        words = text.split()
        logger.info(f"Simulating Push-To-Talk speech input ({len(words)} words)...")

        # Stream partial results
        accumulated = []
        for seq, word in enumerate(words, start=1):
            accumulated.append(word)
            partial_str = " ".join(accumulated)
            partial_payload = {
                "version": "1.0",
                "type": "partial",
                "text": partial_str,
                "sequence": seq,
                "timestamp": int(time.time() * 1000)
            }
            logger.info(f"[PARTIAL STREAM #{seq}]: {partial_str}")
            time.sleep(0.15)

        # Emit final result & inject text
        final_text = text if text.endswith(".") else text + "."
        final_payload = {
            "version": "1.0",
            "type": "final",
            "text": final_text,
            "confidence": 0.98,
            "timestamp": int(time.time() * 1000)
        }
        logger.info(f"[FINAL RESULT]: {final_text}")
        
        # Perform text injection
        self.injector.inject(final_text)
        print(f"✅ Injected: '{final_text}'\n")

    def run_mock_android_server(self):
        logger.info(f"Starting Mock Android TCP Server on {self.host}:{self.port}...")
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind((self.host, self.port))
        except OSError as e:
            logger.error(f"Failed to bind {self.host}:{self.port} - {e}")
            print(f"\n⚠️ [PORT CONFLICT]: Port {self.port} is bound by another process (such as ADB forward rule).")
            print("👉 To run mock server on port 9999, run: adb forward --remove tcp:9999")
            print("👉 Or run mock server on another port: python3 windows/test_mode.py --server --port 9998\n")
            return

        server.listen(1)
        print(f"✅ Mock Android Server listening on {self.host}:{self.port}")
        print("Launch 'python3 windows/main.py' in another terminal to test connection.")

        try:
            while True:
                client, addr = server.accept()
                logger.info(f"Client connected from {addr}")
                
                # Send ready heartbeat
                hb = json.dumps({
                    "version": "1.0",
                    "type": "heartbeat",
                    "status": "ready",
                    "timestamp": int(time.time() * 1000)
                }) + "\n"
                client.sendall(hb.encode("utf-8"))

                buffer = ""
                while True:
                    data = client.recv(1024).decode("utf-8")
                    if not data:
                        break
                    buffer += data
                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        if line.strip():
                            cmd = json.loads(line)
                            logger.info(f"Received Command from Windows: {cmd}")
                            if cmd.get("command") == "start_listening":
                                logger.info("Responding with mock partial streaming...")
                                p1 = json.dumps({"version": "1.0", "type": "partial", "text": "testing hermes", "sequence": 1, "timestamp": int(time.time() * 1000)}) + "\n"
                                client.sendall(p1.encode("utf-8"))
                                time.sleep(0.2)
                            elif cmd.get("command") == "stop_listening":
                                logger.info("Responding with mock final text...")
                                fin = json.dumps({"version": "1.0", "type": "final", "text": "Testing Hermes test mode.", "confidence": 0.99, "timestamp": int(time.time() * 1000)}) + "\n"
                                client.sendall(fin.encode("utf-8"))

                client.close()
                logger.info("Client disconnected.")
        except KeyboardInterrupt:
            logger.info("Stopping mock server.")
        finally:
            server.close()

    def run_fixture_playback(self):
        fixtures_dir = REPO_ROOT / "tests" / "fixtures" / "protocol" / "v1"
        logger.info(f"Playing back protocol payload fixtures from {fixtures_dir}...")
        
        for fixture_file in sorted(fixtures_dir.glob("*.json")):
            with open(fixture_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                logger.info(f"Fixture '{fixture_file.name}': {json.dumps(data)}")
                time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description="Hermes Test Mode & Simulator (REQ-FUNC-011)")
    parser.add_argument("--interactive", action="store_true", help="Run interactive speech simulation")
    parser.add_argument("--server", action="store_true", help="Run mock Android TCP server")
    parser.add_argument("--playback", action="store_true", help="Play back protocol test fixtures")
    parser.add_argument("--port", type=int, default=9999, help="TCP port (default: 9999)")
    args = parser.parse_args()

    sim = TestModeSimulator(port=args.port)

    if args.server:
        sim.run_mock_android_server()
    elif args.playback:
        sim.run_fixture_playback()
    else:
        sim.run_interactive()


if __name__ == "__main__":
    main()
