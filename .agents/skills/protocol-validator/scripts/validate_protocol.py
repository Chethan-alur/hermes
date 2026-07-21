#!/usr/bin/env python3
"""
Protocol Validator Script for Project Hermes
Validates JSON messages and test fixtures against schema contracts in protocol/schemas/v1/
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import jsonschema
except ImportError:
    jsonschema = None


def load_json(filepath: Path) -> dict:
    with open(filepath, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_payload_fallback(payload: dict, schema: dict) -> list:
    """Fallback basic schema check if jsonschema package is not installed."""
    errors = []
    required = schema.get("required", [])
    for field in required:
        if field not in payload:
            errors.append(f"Missing required field '{field}'")
    
    properties = schema.get("properties", {})
    for k, v in payload.items():
        if k in properties:
            expected_const = properties[k].get("const")
            if expected_const is not None and v != expected_const:
                errors.append(f"Field '{k}' must be '{expected_const}', got '{v}'")
            expected_enum = properties[k].get("enum")
            if expected_enum is not None and v not in expected_enum:
                errors.append(f"Field '{k}' value '{v}' not in allowed enum {expected_enum}")
    return errors


def validate_file(json_file: Path, schema_file: Path) -> bool:
    print(f"Validating {json_file.name} against {schema_file.name}...")
    try:
        payload = load_json(json_file)
        schema = load_json(schema_file)
        
        if jsonschema is not None:
            jsonschema.validate(instance=payload, schema=schema)
            print(f"  ✅ [PASS] {json_file.name} is valid against {schema_file.name}")
            return True
        else:
            errors = validate_payload_fallback(payload, schema)
            if errors:
                print(f"  ❌ [FAIL] Validation errors for {json_file.name}:")
                for err in errors:
                    print(f"     - {err}")
                return False
            print(f"  ✅ [PASS] {json_file.name} basic structural check passed (jsonschema package recommended)")
            return True
    except Exception as e:
        print(f"  ❌ [FAIL] Error validating {json_file.name}: {e}")
        return False


def validate_all(repo_root: Path) -> bool:
    schemas_dir = repo_root / "protocol" / "schemas" / "v1"
    fixtures_dir = repo_root / "tests" / "fixtures" / "protocol" / "v1"

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

    all_passed = True
    for fixture_name, schema_name in mappings:
        fixture_path = fixtures_dir / fixture_name
        schema_path = schemas_dir / schema_name
        if not fixture_path.exists():
            print(f"❌ Missing fixture file: {fixture_path}")
            all_passed = False
            continue
        if not schema_path.exists():
            print(f"❌ Missing schema file: {schema_path}")
            all_passed = False
            continue
        
        if not validate_file(fixture_path, schema_path):
            all_passed = False

    return all_passed


def main():
    parser = argparse.ArgumentParser(description="Hermes Protocol Validator")
    parser.add_argument("--file", type=str, help="Path to JSON payload file")
    parser.add_argument("--schema", type=str, help="Path to JSON schema file")
    parser.add_argument("--all", action="store_true", help="Validate all test fixtures against schemas")

    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[4]

    if args.all or (not args.file and not args.schema):
        success = validate_all(repo_root)
        sys.exit(0 if success else 1)
    
    if args.file and args.schema:
        success = validate_file(Path(args.file), Path(args.schema))
        sys.exit(0 if success else 1)
    
    parser.print_help()


if __name__ == "__main__":
    main()
