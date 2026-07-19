import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES_DIR = REPO_ROOT / "tests" / "fixtures" / "protocol" / "v1"


class MockTestModeSimulator:
    """Mock implementation of TestModeSimulator for unit testing fixture playback and event generation."""
    def __init__(self):
        self.events_log = []

    def simulate_speech_sequence(self, partial_text: str, final_text: str):
        self.events_log.append({"type": "partial", "text": partial_text, "sequence": 1})
        self.events_log.append({"type": "final", "text": final_text, "confidence": 0.98})

    def get_events(self) -> list:
        return self.events_log


class TestTestModeSimulator(unittest.TestCase):
    def test_simulation_sequence(self):
        simulator = MockTestModeSimulator()
        simulator.simulate_speech_sequence("create a python", "Create a Python class.")
        
        events = simulator.get_events()
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["type"], "partial")
        self.assertEqual(events[0]["text"], "create a python")
        self.assertEqual(events[1]["type"], "final")
        self.assertEqual(events[1]["text"], "Create a Python class.")

    def test_fixtures_directory_exists(self):
        self.assertTrue(FIXTURES_DIR.exists(), f"Fixtures dir missing: {FIXTURES_DIR}")
        self.assertTrue((FIXTURES_DIR / "final_sample.json").exists())


if __name__ == "__main__":
    unittest.main()
