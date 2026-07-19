import json
import socket
import threading
import time
import logging

logger = logging.getLogger("HermesTCPClient")


class TCPTransportClient:
    """
    TCP Socket Client connecting to Android Foreground Service over ADB port forward (tcp:9999).
    Framing: Newline-delimited JSON messages.
    Features: Auto-reconnection loop (REQ-NFR-005).
    """
    def __init__(self, host: str = "127.0.0.1", port: int = 9999, on_message_callback=None, auto_reconnect: bool = True):
        self.host = host
        self.port = port
        self.on_message = on_message_callback
        self.auto_reconnect = auto_reconnect
        self.socket = None
        self.is_connected = False
        self.running = False
        self.recv_thread = None
        self.reconnect_thread = None

    def start(self):
        self.running = True
        if self.auto_reconnect:
            self.reconnect_thread = threading.Thread(target=self._reconnect_loop, daemon=True)
            self.reconnect_thread.start()
        else:
            self.connect()

    def connect(self) -> bool:
        if self.is_connected:
            return True

        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.settimeout(5.0)
            self.socket.connect((self.host, self.port))
            self.is_connected = True
            logger.info(f"✅ Connected to Android transport server at {self.host}:{self.port}")
            
            self.recv_thread = threading.Thread(target=self._receive_loop, daemon=True)
            self.recv_thread.start()
            return True
        except Exception as e:
            logger.debug(f"Unable to connect to transport server at {self.host}:{self.port}: {e}")
            self._cleanup_socket()
            return False

    def send_json(self, payload: dict) -> bool:
        if not self.is_connected or not self.socket:
            logger.warning("Attempted to send payload while disconnected.")
            return False

        try:
            raw_data = (json.dumps(payload) + "\n").encode("utf-8")
            self.socket.sendall(raw_data)
            logger.debug(f"Sent: {payload}")
            return True
        except Exception as e:
            logger.error(f"Error sending payload: {e}")
            self.disconnect()
            return False

    def disconnect(self):
        self.is_connected = False
        self._cleanup_socket()
        logger.info("TCP socket disconnected.")

    def stop(self):
        self.running = False
        self.disconnect()

    def _cleanup_socket(self):
        self.is_connected = False
        if self.socket:
            try:
                self.socket.close()
            except Exception:
                pass
            self.socket = None

    def _reconnect_loop(self):
        while self.running:
            if not self.is_connected:
                logger.info(f"Attempting connection to Android transport server at {self.host}:{self.port}...")
                self.connect()
            time.sleep(2.0)

    def _receive_loop(self):
        buffer = ""
        while self.running and self.is_connected and self.socket:
            try:
                chunk = self.socket.recv(4096).decode("utf-8")
                if not chunk:
                    logger.warning("Socket connection closed by remote server.")
                    break
                
                buffer += chunk
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if line:
                        self._handle_raw_message(line)
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    logger.error(f"Error in receive loop: {e}")
                break

        self.disconnect()

    def _handle_raw_message(self, raw_line: str):
        try:
            msg = json.loads(raw_line)
            logger.debug(f"Received JSON message: {msg}")
            if self.on_message:
                self.on_message(msg)
        except Exception as e:
            logger.error(f"Failed to parse JSON line: {raw_line} - Error: {e}")
