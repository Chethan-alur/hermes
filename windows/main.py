#!/usr/bin/env python3
"""
Windows Companion Daemon - Project Hermes
Coordinates Global Hotkey, TCP Transport, and Text Injection into active window.
Maintains persistent TCP socket connection to Android companion over port 9999.
Supports F12 ANSI escape sequences (^[[24~) in Linux/WSL terminal mode.
"""

import os
import sys
import json
import time
import select
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


def read_key_nonblocking():
    """Non-blocking key & ANSI escape sequence (e.g. ^[[24~ for F12) reader for Linux/WSL terminal."""
    try:
        import tty
        import termios
        fd = sys.stdin.fileno()
        rlist, _, _ = select.select([fd], [], [], 0.05)
        if rlist:
            old_settings = termios.tcgetattr(fd)
            try:
                tty.setraw(fd)
                ch = sys.stdin.read(1)
                # Check for ANSI escape sequences (F12 emits ^[[24~)
                if ch == "\x1b":
                    r_seq, _, _ = select.select([fd], [], [], 0.05)
                    if r_seq:
                        seq = sys.stdin.read(4)
                        full_seq = ch + seq
                        if "[24~" in full_seq: # F12 ANSI code
                            return "f12"
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
            return ch
    except Exception:
        pass
    return None


class HermesWindowsDaemon:
    # Human-readable labels for the common Win32 virtual-key codes we ship.
    _HOTKEY_LABELS = {"163": "Right Ctrl", "170": "Search", "183": "Calculator", "f12": "F12"}

    def __init__(self, host: str = "127.0.0.1", port: int = 9999, hotkey: str = "163"):
        self.hotkey = str(hotkey)
        self.hotkey_label = self._HOTKEY_LABELS.get(self.hotkey, self.hotkey)
        self.injector = TextInjector()
        self.transport = TCPTransportClient(
            host=host,
            port=port,
            on_message_callback=self.on_protocol_message,
            on_state_change=self.on_transport_state,
        )
        self.hotkey_manager = HotkeyManager(on_command_callback=self.send_command, hotkey_name=self.hotkey)
        self.running = False
        self.is_listening_toggle = False
        self.transport_state = TCPTransportClient.ConnectionState.DISCONNECTED

    def start(self):
        logger.info("Initializing Project Hermes Windows Companion Client...")
        
        # Start TCP Transport auto-reconnection loop (maintains persistent socket connection)
        self.transport.start()

        # Start Global Hotkey Listener (if pynput is available)
        self.hotkey_manager.start()
        self.running = True

        if keyboard is not None:
            logger.info(f"Hermes Companion running with global hotkey! Press/Hold '{self.hotkey_label}' to dictate.")
            try:
                while self.running:
                    time.sleep(1.0)
            except KeyboardInterrupt:
                logger.info("Keyboard interrupt received. Shutting down...")
                self.stop()
        elif not sys.stdin.isatty():
            logger.info("Hermes Companion running in background daemon mode.")
            try:
                while self.running:
                    time.sleep(1.0)
            except (KeyboardInterrupt, SystemExit):
                self.stop()
        else:
            logger.info("Running in Terminal Interactive Mode (WSL / Linux).")
            print("\n" + "=" * 60)
            print("🎙️ Project Hermes Terminal Controller (WSL / Linux Mode)")
            print("=" * 60)
            print("Press [F12] or [SPACEBAR] to START/STOP Push-To-Talk!")
            print("Press [q] to quit.\n")

            try:
                while self.running:
                    ch = read_key_nonblocking()
                    if ch:
                        if ch.lower() in ["q", "\x03"]: # 'q' or Ctrl+C
                            self.stop()
                            break
                        elif ch in [" ", "s", "r", "\r", "\n", "f12"]:
                            self.toggle_push_to_talk()
                    time.sleep(0.05)
            except (KeyboardInterrupt, EOFError):
                logger.info("Shutting down daemon...")
                self.stop()

    def toggle_push_to_talk(self):
        if not self.is_listening_toggle:
            self.is_listening_toggle = True
            print("\n🔴 [LISTENING...] Speak into your phone now! Press [F12]/[SPACEBAR] when finished.")
            self.send_command({
                "version": "1.0",
                "type": "command",
                "command": "start_listening",
                "timestamp": int(time.time() * 1000)
            })
        else:
            self.is_listening_toggle = False
            print("\n⏹️ [STOPPING...] Processing speech output...")
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

    def on_transport_state(self, state: str):
        """Reflect the live transport state so the app never merely appears hung.

        Logged once per transition (see TCPTransportClient state-transition logging)
        rather than once per reconnect attempt.
        """
        self.transport_state = state
        States = TCPTransportClient.ConnectionState
        if state == States.CONNECTED:
            logger.info(f"Transport connected to {self.transport.host}:{self.transport.port}; ready to dictate.")
            print("🔗 Connected to phone. Ready to dictate.")
        elif state == States.CONNECTING:
            logger.info("Transport connecting to phone (auto-retrying in the background)...")
            print("… Connecting to phone (retrying in the background; the app stays responsive)…")
        elif state == States.DISCONNECTED:
            logger.warning("Transport disconnected from phone; will reconnect automatically.")
            print("⚠️ Disconnected from phone; reconnecting automatically…")

    def send_command(self, command_payload: dict):
        command = command_payload.get("command")
        if self.transport_state != TCPTransportClient.ConnectionState.CONNECTED:
            logger.warning(f"Cannot dispatch '{command}': phone not connected (state={self.transport_state}).")
            print(f"⚠️ '{command}' ignored — phone not connected yet.")
            return
        logger.info(f"Dispatching command over persistent socket: {command}")
        self.transport.send_json(command_payload)

    def on_protocol_message(self, message: dict):
        msg_type = message.get("type")
        
        if msg_type == "partial":
            text = message.get("text", "")
            logger.info(f"[PARTIAL STREAM]: {text}")
            print(f"  ... Partial #{message.get('sequence', 0)}: \"{text}\"")
            
        elif msg_type == "final":
            text = message.get("text", "")
            confidence = message.get("confidence", 1.0)
            logger.info(f"[FINAL RESULT (Conf: {confidence})]: {text}")
            print(f"\n✨ [FINAL SPEECH TEXT]: \"{text}\"\n")
            # Inject final text into active target application
            self.injector.inject(text)

        elif msg_type == "error":
            code = message.get("code", "UNKNOWN_ERROR")
            msg = message.get("message", "")
            logger.error(f"[ANDROID ERROR]: {code} - {msg}")
            print(f"\n❌ [ERROR]: {code} - {msg}\n")

        elif msg_type == "heartbeat":
            # Emitted on connect and in reply to each liveness ping (~every 15s);
            # kept at DEBUG so it does not flood the log.
            logger.debug(f"[HEARTBEAT]: Android Server Ready (Status: {message.get('status')})")


def load_config():
    """Resolve the transport endpoint and Push-to-Talk hotkey (host, port, hotkey).

    Reads windows/hermes.config.json — the same file the PowerShell hotkey client uses — so both
    clients share one configuration source. For USB-tethering set ``host`` to the phone's tether IP
    (e.g. 192.168.42.129); for Wi-Fi/mobile over WireGuard set it to the phone's WireGuard IP.

    The ``hotkeys`` list holds Win32 virtual-key codes; its first entry is the active PTT key
    (163 = Right Ctrl, the Project Hermes default per REQ-FUNC-003). The environment variables
    HERMES_HOST / HERMES_PORT / HERMES_HOTKEY override the file when present.
    """
    host, port, hotkey = "127.0.0.1", 9999, "163"  # 163 = Right Ctrl (REQ-FUNC-003)
    config_path = Path(__file__).resolve().parent / "hermes.config.json"
    try:
        if config_path.exists():
            data = json.loads(config_path.read_text(encoding="utf-8"))
            host = str(data.get("host", host))
            port = int(data.get("port", port))
            hk = data.get("hotkeys")
            if isinstance(hk, list) and hk:
                hotkey = str(hk[0])
            elif isinstance(hk, (int, str)) and str(hk):
                hotkey = str(hk)
    except Exception as e:
        logger.warning(f"Could not read {config_path.name}; using defaults ({host}:{port}). {e}")
    host = os.environ.get("HERMES_HOST", host)
    port = int(os.environ.get("HERMES_PORT", port))
    hotkey = os.environ.get("HERMES_HOTKEY", hotkey)
    return host, port, hotkey


def main():
    host, port, hotkey = load_config()
    logger.info(f"Target Android transport endpoint: {host}:{port} (PTT hotkey: {hotkey})")
    daemon = HermesWindowsDaemon(host=host, port=port, hotkey=hotkey)
    daemon.start()


if __name__ == "__main__":
    main()
