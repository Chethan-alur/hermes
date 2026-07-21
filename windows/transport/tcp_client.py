import json
import socket
import threading
import time
import random
import logging

logger = logging.getLogger("HermesTCPClient")


class ConnectionState:
    """Transport lifecycle states surfaced through the ``on_state_change`` callback."""
    CONNECTING = "connecting"
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"


class TCPTransportClient:
    """
    TCP socket client connecting to the Android foreground service over an ADB
    port forward (``tcp:9999``) or the phone's USB-tether / WireGuard IP.

    Framing: newline-delimited JSON messages.

    Robustness and efficiency features (REQ-NFR-005):

    * **Capped exponential backoff with jitter.** A missing phone costs one short
      connect attempt followed by an increasing wait (``initial_backoff`` doubling
      up to ``max_backoff``), never a fixed-interval busy loop. The backoff resets
      the moment a connection succeeds.
    * **Interruptible waits.** ``stop()`` wakes the reconnect and heartbeat threads
      immediately through a :class:`threading.Event` instead of leaving them parked
      for the full backoff interval.
    * **Thread-safe socket access.** A lock guards the socket and connection flag
      shared between the send, receive, reconnect and heartbeat threads; a second
      lock serialises writes so concurrent senders never interleave a frame.
    * **Active liveness watchdog.** The Android server emits a heartbeat only at
      connect and in reply to ``ping``; it is not periodic. This client therefore
      pings on an interval and treats the link as dead when no bytes arrive within
      ``heartbeat_timeout``, so a silently dropped connection (phone unplugged, the
      forward torn down) is detected in seconds rather than at the OS keepalive
      default.
    * **Low-latency, resilient sockets.** ``TCP_NODELAY`` disables Nagle batching so
      single-line commands dispatch immediately; ``SO_KEEPALIVE`` is a backstop.
    * **State-transition logging.** One line per state change rather than one per
      retry, so a disconnected phone no longer floods ``windows.log``.
    """

    # Exposed for callers that want to compare against the state callback argument.
    ConnectionState = ConnectionState

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 9999,
        on_message_callback=None,
        auto_reconnect: bool = True,
        on_state_change=None,
        connect_timeout: float = 3.0,
        initial_backoff: float = 1.0,
        max_backoff: float = 30.0,
        heartbeat_interval: float = 15.0,
        heartbeat_timeout: float = 45.0,
        enable_heartbeat: bool = True,
    ):
        self.host = host
        self.port = port
        self.on_message = on_message_callback
        self.on_state_change = on_state_change
        self.auto_reconnect = auto_reconnect

        self.connect_timeout = connect_timeout
        self.initial_backoff = initial_backoff
        self.max_backoff = max_backoff
        self.heartbeat_interval = heartbeat_interval
        self.heartbeat_timeout = heartbeat_timeout
        self.enable_heartbeat = enable_heartbeat

        self.socket = None
        self.is_connected = False
        self.running = False

        self._lock = threading.Lock()          # guards self.socket / self.is_connected
        self._write_lock = threading.Lock()    # serialises sendall() so frames never interleave
        self._wakeup = threading.Event()       # interrupts backoff / heartbeat waits on stop()
        self._last_recv = 0.0                  # time.monotonic() of the last bytes received
        self._state = ConnectionState.DISCONNECTED

        self.recv_thread = None
        self.reconnect_thread = None
        self.heartbeat_thread = None

    # ------------------------------------------------------------------ lifecycle

    def start(self):
        self.running = True
        self._wakeup.clear()
        if self.auto_reconnect:
            self.reconnect_thread = threading.Thread(
                target=self._reconnect_loop, name="hermes-reconnect", daemon=True
            )
            self.reconnect_thread.start()
        else:
            self.connect()

    def stop(self):
        self.running = False
        self._wakeup.set()  # wake any interruptible wait immediately
        self.disconnect()
        for t in (self.reconnect_thread, self.heartbeat_thread, self.recv_thread):
            if t and t.is_alive() and t is not threading.current_thread():
                t.join(timeout=2.0)

    # ---------------------------------------------------------------- connection

    def connect(self) -> bool:
        if self.is_connected:
            return True

        self._set_state(ConnectionState.CONNECTING)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(self.connect_timeout)
        self._configure_socket(sock)
        try:
            sock.connect((self.host, self.port))
        except Exception as e:
            logger.debug(f"Unable to connect to {self.host}:{self.port}: {e}")
            self._safe_close(sock)
            return False

        # Short poll timeout so the receive loop notices stop() / drops promptly.
        sock.settimeout(1.0)
        with self._lock:
            self.socket = sock
            self.is_connected = True
            self._last_recv = time.monotonic()

        logger.info(f"Connected to Android transport server at {self.host}:{self.port}")
        self._set_state(ConnectionState.CONNECTED)

        self.recv_thread = threading.Thread(
            target=self._receive_loop, args=(sock,), name="hermes-recv", daemon=True
        )
        self.recv_thread.start()

        if self.enable_heartbeat:
            self.heartbeat_thread = threading.Thread(
                target=self._heartbeat_loop, args=(sock,), name="hermes-heartbeat", daemon=True
            )
            self.heartbeat_thread.start()
        return True

    def disconnect(self):
        with self._lock:
            was_connected = self.is_connected
            self.is_connected = False
            sock = self.socket
            self.socket = None
        self._safe_close(sock)
        if was_connected:
            logger.info("Transport disconnected.")
        self._set_state(ConnectionState.DISCONNECTED)

    # ------------------------------------------------------------------- sending

    def send_json(self, payload: dict) -> bool:
        with self._lock:
            sock = self.socket if self.is_connected else None
        if sock is None:
            logger.warning("Attempted to send payload while disconnected; dropping.")
            return False

        raw_data = (json.dumps(payload) + "\n").encode("utf-8")
        try:
            with self._write_lock:
                sock.sendall(raw_data)
            logger.debug(f"Sent: {payload}")
            return True
        except Exception as e:
            logger.warning(f"Error sending payload ({e}); dropping connection to reconnect.")
            self.disconnect()
            return False

    # ------------------------------------------------------------ internal loops

    def _reconnect_loop(self):
        backoff = self.initial_backoff
        announced = False
        while self.running:
            if self.is_connected:
                # Connected: poll briefly so a drop reported by the receive loop is
                # picked up quickly, while staying responsive to stop().
                self._wakeup.wait(1.0)
                continue

            if not announced:
                logger.info(
                    f"Attempting connection to Android transport server at "
                    f"{self.host}:{self.port} (auto-retrying with backoff until reachable)..."
                )
                announced = True
            else:
                logger.debug(f"Reconnect attempt to {self.host}:{self.port} (backoff {backoff:.1f}s).")

            if self.connect():
                backoff = self.initial_backoff
                announced = False
                continue

            # Failed: wait with jittered backoff, interruptible by stop().
            delay = min(backoff, self.max_backoff)
            delay += random.uniform(0, delay * 0.1)  # jitter avoids lock-step retries
            self._wakeup.wait(delay)
            backoff = min(backoff * 2, self.max_backoff)

    def _receive_loop(self, sock):
        buffer = b""
        while self.running and self.is_connected and self.socket is sock:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                continue
            except OSError as e:
                if self.running:
                    logger.debug(f"Receive loop ended: {e}")
                break

            if not chunk:
                logger.info("Transport server closed the connection.")
                break

            self._last_recv = time.monotonic()
            buffer += chunk
            # Decode only complete lines so a multi-byte UTF-8 character split
            # across two recv() calls is never mangled.
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                text = line.strip().decode("utf-8", errors="replace")
                if text:
                    self._handle_raw_message(text)

        self.disconnect()

    def _heartbeat_loop(self, sock):
        """Ping on an interval and force a reconnect if the link goes silent.

        Scoped to a single connection via ``sock``: a reconnect installs a new
        socket, which ends this loop and starts a fresh one.
        """
        while self.running and self.is_connected and self.socket is sock:
            if self._wakeup.wait(self.heartbeat_interval):
                return  # stop() requested
            if not (self.is_connected and self.socket is sock):
                return

            idle = time.monotonic() - self._last_recv
            if idle > self.heartbeat_timeout:
                logger.warning(
                    f"No data from transport server for {idle:.1f}s "
                    f"(> {self.heartbeat_timeout:.1f}s timeout); treating link as dead."
                )
                self.disconnect()
                return

            # Prompt a heartbeat reply to keep the liveness clock fresh.
            self.send_json({
                "version": "1.0",
                "type": "command",
                "command": "ping",
                "timestamp": int(time.time() * 1000),
            })

    def _handle_raw_message(self, raw_line: str):
        try:
            msg = json.loads(raw_line)
            logger.debug(f"Received JSON message: {msg}")
            if self.on_message:
                self.on_message(msg)
        except Exception as e:
            logger.error(f"Failed to parse JSON line: {raw_line} - Error: {e}")

    # ------------------------------------------------------------------- helpers

    def _configure_socket(self, sock):
        """Best-effort low-latency / keepalive tuning; ignore unsupported options."""
        for level, option in ((socket.IPPROTO_TCP, socket.TCP_NODELAY),
                              (socket.SOL_SOCKET, socket.SO_KEEPALIVE)):
            try:
                sock.setsockopt(level, option, 1)
            except OSError:
                pass

    def _set_state(self, state: str):
        if state == self._state:
            return
        self._state = state
        if self.on_state_change:
            try:
                self.on_state_change(state)
            except Exception as e:
                logger.debug(f"on_state_change callback raised: {e}")

    @staticmethod
    def _safe_close(sock):
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass
