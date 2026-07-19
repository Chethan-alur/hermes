---
name: protocol-validator
description: Validate JSON payload messages and protocol fixtures against Project Hermes JSON Schemas in protocol/schemas/v1/.
---

# Protocol Validator Skill

This skill provides automated validation of JSON protocol payloads and test fixtures against the official JSON schemas in `protocol/schemas/v1/`.

## Usage Instructions

Run the python validation script from the repository root:

```bash
python3 .agents/skills/protocol-validator/scripts/validate_protocol.py
```

### Options
- Validate specific file against a schema:
  ```bash
  python3 .agents/skills/protocol-validator/scripts/validate_protocol.py --file tests/fixtures/protocol/v1/command_start.json --schema protocol/schemas/v1/command.schema.json
  ```
- Validate all sample fixtures against all schemas:
  ```bash
  python3 .agents/skills/protocol-validator/scripts/validate_protocol.py --all
  ```
