import json
import unittest
from pathlib import Path

try:
    import jsonschema
except ImportError:
    jsonschema = None

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMAS_DIR = REPO_ROOT / "protocol" / "schemas" / "v1"
FIXTURES_DIR = REPO_ROOT / "tests" / "fixtures" / "protocol" / "v1"


def load_json(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


class TestProtocolSchemas(unittest.TestCase):
    def test_all_fixtures_against_schemas(self):
        mappings = [
            ("command_start.json", "command.schema.json"),
            ("command_stop.json", "command.schema.json"),
            ("partial_sample.json", "partial.schema.json"),
            ("final_sample.json", "final.schema.json"),
            ("error_sample.json", "error.schema.json"),
            ("heartbeat_sample.json", "heartbeat.schema.json"),
        ]

        for fixture_filename, schema_filename in mappings:
            fixture_path = FIXTURES_DIR / fixture_filename
            schema_path = SCHEMAS_DIR / schema_filename

            self.assertTrue(fixture_path.exists(), f"Fixture file missing: {fixture_path}")
            self.assertTrue(schema_path.exists(), f"Schema file missing: {schema_path}")

            payload = load_json(fixture_path)
            schema = load_json(schema_path)

            if jsonschema is not None:
                jsonschema.validate(instance=payload, schema=schema)
            else:
                self.assertIn("version", payload)
                self.assertIn("type", payload)
                self.assertEqual(payload["version"], "1.0")


if __name__ == "__main__":
    unittest.main()
