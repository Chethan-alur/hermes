import os
import sys
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))


class MockHotkeyListener:
    """Mock implementation of HotkeyListener for unit testing state transitions."""
    def __init__(self, callback):
        self.callback = callback
        self.is_pressed = False
        self.state = "IDLE"

    def press_right_ctrl(self):
        if not self.is_pressed:
            self.is_pressed = True
            self.state = "LISTENING"
            self.callback({
                "version": "1.0",
                "type": "command",
                "command": "start_listening",
                "timestamp": int(time.time() * 1000)
            })

    def release_right_ctrl(self):
        if self.is_pressed:
            self.is_pressed = False
            self.state = "IDLE"
            self.callback({
                "version": "1.0",
                "type": "command",
                "command": "stop_listening",
                "timestamp": int(time.time() * 1000)
            })


class TestHotkeyListener(unittest.TestCase):
    def test_hotkey_press_and_release_events(self):
        received_commands = []

        def on_command(cmd):
            received_commands.append(cmd)

        listener = MockHotkeyListener(callback=on_command)
        self.assertEqual(listener.state, "IDLE")

        # Simulate Right-Ctrl Press
        listener.press_right_ctrl()
        self.assertEqual(listener.state, "LISTENING")
        self.assertEqual(len(received_commands), 1)
        self.assertEqual(received_commands[0]["command"], "start_listening")

        # Simulate Right-Ctrl Release
        listener.release_right_ctrl()
        self.assertEqual(listener.state, "IDLE")
        self.assertEqual(len(received_commands), 2)
        self.assertEqual(received_commands[1]["command"], "stop_listening")


# --------------------------------------------------------------------------- #
# REQ-FUNC-003 — the real HotkeyManager must match Right Ctrl (VK 163), which
# pynput delivers as the `Key.ctrl_r` enum member (which has no `.vk`).
# --------------------------------------------------------------------------- #

class _FakeKey:
    """Emulates a pynput `Key` enum member (special key, no `.vk` attribute)."""
    def __init__(self, name):
        self.name = name

    def __eq__(self, other):
        return isinstance(other, _FakeKey) and other.name == self.name

    def __hash__(self):
        return hash(self.name)


class _FakeKeyCode:
    """Emulates a pynput `KeyCode` (regular key, carries a `.vk`)."""
    def __init__(self, vk):
        self.vk = vk


class _FakeKeyboard:
    class Key:
        ctrl_r = _FakeKey("ctrl_r")
        f12 = _FakeKey("f12")


class TestHotkeyManagerMatching(unittest.TestCase):
    """Exercise the real `HotkeyManager._is_target_key` with a fake keyboard backend."""

    def _manager(self, hotkey_name):
        import windows.hotkeys.hotkey_manager as hkm
        self._hkm = hkm
        self._saved = hkm.keyboard
        hkm.keyboard = _FakeKeyboard  # pynput is not installed in CI/WSL
        return hkm.HotkeyManager(on_command_callback=lambda _: None, hotkey_name=hotkey_name)

    def tearDown(self):
        if getattr(self, "_hkm", None) is not None:
            self._hkm.keyboard = self._saved

    def test_right_ctrl_vk163_matches_ctrl_r_enum(self):
        mgr = self._manager("163")
        self.assertTrue(mgr._is_target_key(_FakeKeyboard.Key.ctrl_r),
                        "VK 163 hotkey must match the Key.ctrl_r enum member")

    def test_right_ctrl_matches_keycode_with_vk163(self):
        mgr = self._manager("163")
        self.assertTrue(mgr._is_target_key(_FakeKeyCode(163)))

    def test_right_ctrl_does_not_match_other_keys(self):
        mgr = self._manager("163")
        self.assertFalse(mgr._is_target_key(_FakeKeyboard.Key.f12))
        self.assertFalse(mgr._is_target_key(_FakeKeyCode(999)))

    def test_f12_regression_still_matches(self):
        mgr = self._manager("f12")
        self.assertTrue(mgr._is_target_key(_FakeKeyboard.Key.f12))
        self.assertFalse(mgr._is_target_key(_FakeKeyboard.Key.ctrl_r))


class TestLoadConfigHotkey(unittest.TestCase):
    """`load_config` must resolve the configured hotkey, not hardcode f12."""

    def setUp(self):
        for var in ("HERMES_HOTKEY", "HERMES_HOST", "HERMES_PORT"):
            os.environ.pop(var, None)

    def tearDown(self):
        os.environ.pop("HERMES_HOTKEY", None)

    def test_load_config_returns_hotkey(self):
        import windows.main as m
        result = m.load_config()
        self.assertEqual(len(result), 3, "load_config must return (host, port, hotkey)")
        _, _, hotkey = result
        # The committed windows/hermes.config.json sets hotkeys=[163] (Right Ctrl).
        self.assertEqual(str(hotkey), "163")

    def test_env_override(self):
        import windows.main as m
        os.environ["HERMES_HOTKEY"] = "f12"
        _, _, hotkey = m.load_config()
        self.assertEqual(str(hotkey), "f12")


if __name__ == "__main__":
    unittest.main()
