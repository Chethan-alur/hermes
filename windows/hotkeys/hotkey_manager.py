import time
import logging

logger = logging.getLogger("HermesHotkey")

try:
    from pynput import keyboard
except ImportError:
    keyboard = None


class HotkeyManager:
    """
    Global hotkey manager listening for Push-To-Talk (Right Ctrl hold).
    Emits JSON command payloads on keydown and keyup events.
    """
    def __init__(self, on_command_callback, hotkey_name: str = "f12", suppress: bool = False):
        self.on_command = on_command_callback
        self.hotkey_name = hotkey_name
        self.suppress = suppress
        self.is_pressed = False
        self.listener = None

    def start(self):
        if keyboard is None:
            logger.warning("pynput not available; HotkeyManager running in manual/mock mode.")
            return

        logger.info(f"Starting global hotkey listener for key: {self.hotkey_name} (suppress={self.suppress})")
        self.listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
            suppress=self.suppress
        )
        self.listener.start()

    def stop(self):
        if self.listener:
            self.listener.stop()
            self.listener = None

    def _on_press(self, key):
        logger.debug(f"[RAW KEY PRESS]: {key}")
        if self._is_target_key(key):
            logger.info(f"🔑 [HOTKEY EVENT] {self.hotkey_name.upper()} KEY DOWN detected! (is_pressed state={self.is_pressed})")
            if not self.is_pressed:
                self.is_pressed = True
                logger.info("📡 [HOTKEY COMMAND] Emitting 'start_listening' payload to Android...")
                self.on_command({
                    "version": "1.0",
                    "type": "command",
                    "command": "start_listening",
                    "timestamp": int(time.time() * 1000)
                })

    def _on_release(self, key):
        logger.debug(f"[RAW KEY RELEASE]: {key}")
        if self._is_target_key(key):
            logger.info(f"🔑 [HOTKEY EVENT] {self.hotkey_name.upper()} KEY UP detected! (is_pressed state={self.is_pressed})")
            if self.is_pressed:
                self.is_pressed = False
                logger.info("📡 [HOTKEY COMMAND] Emitting 'stop_listening' payload to Android...")
                self.on_command({
                    "version": "1.0",
                    "type": "command",
                    "command": "stop_listening",
                    "timestamp": int(time.time() * 1000)
                })

    def _is_target_key(self, key) -> bool:
        if keyboard is None:
            return False
        
        # Match F12 default
        if self.hotkey_name == "f12" and key == keyboard.Key.f12:
            return True

        # Match Calculator Key (VK 183 / VK_LAUNCH_APP2)
        if self.hotkey_name == "calculator":
            if hasattr(key, 'vk') and key.vk in [183, 0xB7, 0x97]:
                return True

        # Match generic Virtual Keycode (VK) number
        if hasattr(key, 'vk') and str(key.vk) == str(self.hotkey_name):
            return True

        # Match pynput named key
        if hasattr(keyboard.Key, self.hotkey_name) and key == getattr(keyboard.Key, self.hotkey_name):
            return True

        return False
