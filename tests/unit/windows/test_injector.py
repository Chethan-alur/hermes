import unittest


class MockTextInjector:
    """Mock implementation of TextInjector for unit testing text formatting & injection."""
    def __init__(self):
        self.buffer = []

    def inject_text(self, text: str):
        if not text:
            return
        self.buffer.append(text)

    def get_full_text(self) -> str:
        return "".join(self.buffer)


class TestTextInjector(unittest.TestCase):
    def test_text_injector_append(self):
        injector = MockTextInjector()
        injector.inject_text("Hello ")
        injector.inject_text("world!")
        self.assertEqual(injector.get_full_text(), "Hello world!")
        self.assertEqual(len(injector.buffer), 2)

    def test_text_injector_empty(self):
        injector = MockTextInjector()
        injector.inject_text("")
        self.assertEqual(injector.get_full_text(), "")
        self.assertEqual(len(injector.buffer), 0)


if __name__ == "__main__":
    unittest.main()
