#!/usr/bin/env python3
"""
Windows Companion Daemon - Project Hermes
Coordinates Global Hotkey, TCP Transport, and Text Injection into active window.
Includes interactive CLI fallback for WSL/Linux test environments.
"""

import sys
import time
import logging
from pathlib import Path

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from windows.hotkeys.hotkey_manager import HotkeyManager, keyboard
from windows.transport.tcp_client import TCPTransportClient
from windows.injector.text_injector import TextInjector

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] (%(name)s) %(message)s"
)
logger = logging.getLogger("HermesWindowsMain")


class HermesWindowsDaemon:
    def __init__(self, host: str = "127.0.0.1", port: int = 9999):
        self.injector = TextInjector()
        self.transport = TCPTransportClient(host=host, port=port, on_message_callback=self.on_protocol_message)
        self.hotkey_manager = HotkeyManager(on_command_callback=self.send_command)
        self.running = False
        self.is_listening_toggle = False

    def start(self):
        logger.info("Initializing Project Hermes Windows Companion Client...")
        
        # Start TCP Transport auto-reconnection loop
        self.transport.start()

        # Start Global Hotkey Listener (if pynput is available)
        self.hotkey_manager.start()
        self.running = True

        if keyboard is not None:
            logger.info("Hermes Companion running with global hotkey! Hold 'Right Ctrl' to dictate.")
            try:
                while self.running:
                    time.sleep(1.0)
            except KeyboardInterrupt:
                logger.info("Keyboard interrupt received. Shutting down...")
                self.stop()
        else:
            logger.info("Running in Terminal Interactive Mode (pynput missing/WSL environment).")
            print("\n" + "=" * 60)
            print("🎙️ Project Hermes Terminal Controller (WSL / Linux Mode)")
            print("=" * 60)
            print("Press [Enter] to START listening -> Speak into phone -> Press [Enter] to STOP listening.")
            print("Type 'q' and press [Enter] to quit.\n")

            try:
                while self.running:
                    user_input = input("Press [Enter] to toggle Push-To-Talk (or 'q' to quit) > ").strip()
                    if user_input.lower() in ["q", "quit", "exit"]:
                        self.stop()
                        break
                    
                    self.toggle_push_to_talk()
            except (KeyboardInterrupt, EOFError):
                logger.info("Keyboard interrupt received. Shutting down...")
                self.stop()

    def toggle_push_to_talk(self):
        if not self.is_listening_toggle:
            self.is_listening_toggle = True
            print("🔴 [LISTENING...] Speak into your phone now!")
            self.send_command({
                "version": "1.0",
                "type": "command",
                "command": "start_listening",
                "timestamp": int(time.time() * 1000)
            })
        else:
            self.is_listening_toggle = False
            print("⏹️ [STOPPING...] Processing speech output...")
            self.send_command({
                "version": "1.0",
                "type": "command",
                "command": "stop_listening",
                "timestamp": int(time.time() * 1000)
            })

    def stop(self):
        self.running = False
        self.hotkey_manager.stop()
        self.transport.stop()
        logger.info("Hermes Windows Companion stopped.")

    def send_command(self, command_payload: dict):
        logger.info(f"Dispatching command: {command_payload.get('command')}")
        self.transport.send_json(command_payload)

    def on_protocol_message(self, message: dict):
        msg_type = message.get("type")
        
        if msg_type == "partial":
            text = message.get("text", "")
            logger.info(f"[PARTIAL STREAM]: {text}")
            print(f"  ... {text}")
            
        elif msg_type == "final":
            text = message.get("text", "")
            confidence = message.get("confidence", 1.0)
            logger.info(f"[FINAL RESULT (Conf: {confidence})]: {text}")
            print(f"\n✨ [FINAL SPEECH TEXT]: {text}\n")
            # Inject final text into active target application
            self.injector.inject(text)

        elif msg_type == "error":
            code = message.get("code", "UNKNOWN_ERROR")
            msg = message.get("message", "")
            logger.error(f"[ANDROID ERROR]: {code} - {msg}")
            print(f"\n❌ [ERROR]: {code} - {msg}\n")

        elif msg_type == "heartbeat":
            logger.debug(f"[HEARTBEAT]: Status={message.get('status')}")


def main():
    daemon = HermesWindowsDaemon()
    daemon.start()


if __name__ == "__main__":
    main()
