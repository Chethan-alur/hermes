import logging

logger = logging.getLogger("HermesTextInjector")

try:
    import win32api
    import win32con
    import win32clipboard
    WIN32_AVAILABLE = True
except ImportError:
    WIN32_AVAILABLE = False


class TextInjector:
    """
    Injects transcribed text directly into the currently focused active window.
    Strategies:
      1. SendInput (Real-time keystroke character injection)
      2. Clipboard (Fallback bulk paste via Ctrl+V)
    """
    def __init__(self, use_clipboard_fallback: bool = False):
        self.use_clipboard_fallback = use_clipboard_fallback
        if not WIN32_AVAILABLE:
            logger.info("Win32 APIs not available. Running TextInjector in fallback mode.")

    def inject(self, text: str) -> bool:
        if not text:
            return True

        logger.info(f"Injecting text string ({len(text)} chars): '{text}'")

        if not WIN32_AVAILABLE:
            print(f"\n[TEXT INJECTED]: {text}")
            return True

        if self.use_clipboard_fallback:
            return self._inject_via_clipboard(text)
        else:
            return self._inject_via_keystrokes(text)

    def _inject_via_keystrokes(self, text: str) -> bool:
        try:
            for char in text:
                # Send Unicode character press & release
                win32api.keybd_event(0, ord(char), win32con.KEYEVENTF_UNICODE, 0)
                win32api.keybd_event(0, ord(char), win32con.KEYEVENTF_UNICODE | win32con.KEYEVENTF_KEYUP, 0)
            return True
        except Exception as e:
            logger.error(f"Keystroke injection failed: {e}. Falling back to clipboard.")
            return self._inject_via_clipboard(text)

    def _inject_via_clipboard(self, text: str) -> bool:
        try:
            win32clipboard.OpenClipboard()
            win32clipboard.EmptyClipboard()
            win32clipboard.SetClipboardText(text, win32clipboard.CF_UNICODETEXT)
            win32clipboard.CloseClipboard()

            # Simulate Ctrl+V key press
            win32api.keybd_event(win32con.VK_CONTROL, 0, 0, 0)
            win32api.keybd_event(ord('V'), 0, 0, 0)
            win32api.keybd_event(ord('V'), 0, win32con.KEYEVENTF_KEYUP, 0)
            win32api.keybd_event(win32con.VK_CONTROL, 0, win32con.KEYEVENTF_KEYUP, 0)
            return True
        except Exception as e:
            logger.error(f"Clipboard injection failed: {e}")
            return False
