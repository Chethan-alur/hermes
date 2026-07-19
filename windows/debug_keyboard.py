#!/usr/bin/env python3
"""
Keyboard Event Diagnostic Tool - Project Hermes
Detects and displays exact Key Down and Key Up events, scan codes, and hold duration.
Works natively on Windows (via pynput) and Linux/WSL.
"""

import sys
import time
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

def run_windows_native_detector():
    try:
        from pynput import keyboard
    except ImportError:
        print("❌ 'pynput' library is not installed in this Python environment.")
        print("👉 Install it with: pip install pynput\n")
        return False

    press_times = {}

    print("=" * 65)
    print("🔑 Windows Global Keyboard Hook Detector Active (pynput)")
    print("=" * 65)
    print("Press ANY key (e.g., Right Ctrl, F1-F12, Space) to test press/release.")
    print("Press [Esc] or Ctrl+C to exit.\n")

    def on_press(key):
        key_str = str(key)
        if key_str not in press_times:
            press_times[key_str] = time.time()
            print(f"🟢 [KEY DOWN]  : {key_str:<25} (Time: {time.strftime('%H:%m:%S')})")

    def on_release(key):
        key_str = str(key)
        start_t = press_times.pop(key_str, None)
        duration_ms = (time.time() - start_t) * 1000 if start_t else 0
        print(f"🔴 [KEY UP]    : {key_str:<25} (Held for {duration_ms:.1f} ms)")

        if key == keyboard.Key.esc:
            print("\n[Esc] pressed. Exiting keyboard detector.")
            return False

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
    return True


def run_terminal_key_detector():
    print("=" * 65)
    print("⌨️ Terminal Single-Key Press Detector (Linux / WSL Mode)")
    print("=" * 65)
    print("Press any key in this terminal window to inspect its raw keycode.")
    print("Press [q] to exit.\n")

    try:
        import tty
        import termios
        fd = sys.stdin.fileno()
        old_settings = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            while True:
                ch = sys.stdin.read(1)
                if ch.lower() == 'q' or ch == '\x03':
                    break
                ord_val = repr(ch)
                hex_val = hex(ord(ch))
                print(f"\r\n🟢 [KEY PRESS DETECTED]: Char={ord_val:<10} Hex={hex_val:<8} ASCII={ord(ch)}", end="")
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
            print("\r\n")
    except Exception as e:
        print(f"Terminal detector exception: {e}")


def main():
    print("\n🔍 Hermes Keyboard Event Inspector\n")
    success = run_windows_native_detector()
    if not success:
        run_terminal_key_detector()


if __name__ == "__main__":
    main()
