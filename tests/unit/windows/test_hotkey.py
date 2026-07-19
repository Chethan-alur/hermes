import time
import unittest


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


if __name__ == "__main__":
    unittest.main()
