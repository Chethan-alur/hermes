import json
import re
import unittest
from pathlib import Path

try:
    import jsonschema
except ImportError:
    jsonschema = None

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMAS_DIR = REPO_ROOT / "protocol" / "schemas" / "v1"
FIXTURES_DIR = REPO_ROOT / "tests" / "fixtures" / "protocol" / "v1"
TRANSPORT_KT = (
    REPO_ROOT / "android" / "app" / "src" / "main" / "java"
    / "com" / "hermes" / "transport" / "TransportServerService.kt"
)


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
            ("error_network_timeout.json", "error.schema.json"),
            ("error_recognizer_busy.json", "error.schema.json"),
            ("error_insufficient_permissions.json", "error.schema.json"),
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

    def test_error_schema_covers_all_android_emitted_codes(self):
        """REQ-NFR-006: every code the Android engine emits must exist in error.schema.json.

        Guards against the enum drift where getErrorCodeString emitted codes
        (NETWORK_TIMEOUT, RECOGNIZER_BUSY, ...) that were absent from the schema,
        causing real error frames to fail validation.
        """
        error_schema = load_json(SCHEMAS_DIR / "error.schema.json")
        schema_codes = set(error_schema["properties"]["code"]["enum"])

        kt = TRANSPORT_KT.read_text(encoding="utf-8", errors="replace")
        block = re.search(r"fun getErrorCodeString\(.*?\{(.*?)\n\s{4}\}", kt, re.DOTALL)
        self.assertIsNotNone(block, "getErrorCodeString definition not found in Kotlin source")
        emitted = set(re.findall(r'->\s*"([A-Z_]+)"', block.group(1)))
        self.assertTrue(emitted, "no error codes parsed from getErrorCodeString")

        orphans = emitted - schema_codes
        self.assertEqual(orphans, set(),
                         f"Android emits codes absent from error.schema.json: {sorted(orphans)}")


if __name__ == "__main__":
    unittest.main()
