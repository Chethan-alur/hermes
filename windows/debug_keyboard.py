#!/usr/bin/env python3
"""
Keyboard Event Diagnostic Tool - Project Hermes
Detects and displays exact Key Down and Key Up events, scan codes, virtual keycodes (VK),
and special keys like Calculator (VK_LAUNCH_APP2 / 183), Mail, Media keys, F1-F12, etc.
"""

import sys
import time
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

# Windows Virtual Keycode Map for Special / Media / Launch Keys
SPECIAL_VK_MAP = {
    183: "CALCULATOR (VK_LAUNCH_APP2)",
    182: "MY_COMPUTER (VK_LAUNCH_APP1)",
    180: "MAIL (VK_LAUNCH_MAIL)",
    181: "MEDIA_SELECT (VK_LAUNCH_MEDIA_SELECT)",
    179: "MEDIA_PLAY_PAUSE (VK_MEDIA_PLAY_PAUSE)",
    178: "MEDIA_STOP (VK_MEDIA_STOP)",
    176: "MEDIA_NEXT (VK_MEDIA_NEXT_TRACK)",
    177: "MEDIA_PREV (VK_MEDIA_PREV_TRACK)",
    173: "VOLUME_MUTE (VK_VOLUME_MUTE)",
    174: "VOLUME_DOWN (VK_VOLUME_DOWN)",
    175: "VOLUME_UP (VK_VOLUME_UP)",
    172: "BROWSER_HOME (VK_BROWSER_HOME)",
    162: "LEFT_CTRL",
    163: "RIGHT_CTRL",
    164: "LEFT_ALT",
    165: "RIGHT_ALT",
    160: "LEFT_SHIFT",
    161: "RIGHT_SHIFT",
}

def format_key_event(key):
    key_name = str(key)
    vk_info = ""
    
    if hasattr(key, 'vk') and key.vk:
        vk = key.vk
        vk_name = SPECIAL_VK_MAP.get(vk, f"VK_{vk}")
        vk_info = f" [VK Code: {vk} ({hex(vk)}) -> {vk_name}]"
        key_name = f"{vk_name} ({key})"
    elif hasattr(key, 'char') and key.char:
        key_name = f"Char '{key.char}'"

    return key_name, vk_info


def run_windows_native_detector():
    try:
        from pynput import keyboard
    except ImportError:
        print("❌ 'pynput' library is not installed in this Python environment.")
        print("👉 Install it with: pip install pynput\n")
        return False

    press_times = {}

    print("=" * 75)
    print("🔑 Windows Global Keyboard Hook Detector Active (pynput)")
    print("=" * 75)
    print("Press ANY key (Calculator, Media keys, Right Ctrl, F1-F12, Space) to test.")
    print("Press [Esc] or Ctrl+C to exit.\n")

    def on_press(key):
        key_name, vk_info = format_key_event(key)
        if key_name not in press_times:
            press_times[key_name] = time.time()
            print(f"🟢 [KEY DOWN]  : {key_name:<35}{vk_info} (Time: {time.strftime('%H:%M:%S')})")

    def on_release(key):
        key_name, vk_info = format_key_event(key)
        start_t = press_times.pop(key_name, None)
        duration_ms = (time.time() - start_t) * 1000 if start_t else 0
        print(f"🔴 [KEY UP]    : {key_name:<35} (Held for {duration_ms:.1f} ms)")

        if key == keyboard.Key.esc:
            print("\n[Esc] pressed. Exiting keyboard detector.")
            return False

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
    return True


def run_terminal_key_detector():
    print("=" * 75)
    print("⌨️ Terminal Single-Key Press Detector (Linux / WSL Mode)")
    print("=" * 75)
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
