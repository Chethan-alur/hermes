#!/usr/bin/env python3
"""
Windows Companion Daemon - Project Hermes
Coordinates Global Hotkey, TCP Transport, and Text Injection into active window.
"""

import sys
import time
import logging
from pathlib import Path

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from windows.hotkeys.hotkey_manager import HotkeyManager
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

    def start(self):
        logger.info("Initializing Project Hermes Windows Companion Client...")
        
        # Connect TCP Transport to Android over ADB
        connected = self.transport.connect()
        if not connected:
            logger.warning("Could not connect to Android transport server. Ensure ADB forward is active (adb forward tcp:9999 tcp:9999) and phone app is running.")

        # Start Global Hotkey Listener
        self.hotkey_manager.start()
        self.running = True
        logger.info("Hermes Windows Companion running! Hold 'Right Ctrl' to dictate.")

        try:
            while self.running:
                time.sleep(1.0)
        except KeyboardInterrupt:
            logger.info("Keyboard interrupt received. Shutting down...")
            self.stop()

    def stop(self):
        self.running = False
        self.hotkey_manager.stop()
        self.transport.disconnect()
        logger.info("Hermes Windows Companion stopped.")

    def send_command(self, command_payload: dict):
        logger.info(f"Dispatching command: {command_payload.get('command')}")
        self.transport.send_json(command_payload)

    def on_protocol_message(self, message: dict):
        msg_type = message.get("type")
        
        if msg_type == "partial":
            text = message.get("text", "")
            logger.info(f"[PARTIAL STREAM]: {text}")
            
        elif msg_type == "final":
            text = message.get("text", "")
            confidence = message.get("confidence", 1.0)
            logger.info(f"[FINAL RESULT (Conf: {confidence})]: {text}")
            # Inject final text into active target application
            self.injector.inject(text)

        elif msg_type == "error":
            code = message.get("code", "UNKNOWN_ERROR")
            msg = message.get("message", "")
            logger.error(f"[ANDROID ERROR]: {code} - {msg}")

        elif msg_type == "heartbeat":
            logger.debug(f"[HEARTBEAT]: Status={message.get('status')}")


def main():
    daemon = HermesWindowsDaemon()
    daemon.start()


if __name__ == "__main__":
    main()
