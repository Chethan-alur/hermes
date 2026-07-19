# Hermes Protocol Contract Specification

> **Contract-First Communication Schema Definitions for Project Hermes**

## Overview

All inter-process communication between the Windows Companion application and the Android Companion service uses strictly versioned, newline-delimited JSON messages (`\n` terminated raw TCP frames).

The schemas in `protocol/schemas/v1/` serve as the **single source of truth** for both clients.

---

## Protocol Schemas (`protocol/schemas/v1/`)

| Schema File | Message Type | Description |
| :--- | :--- | :--- |
| [`command.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/command.schema.json) | `command` | Control frames sent from Windows to Android (`start_listening`, `stop_listening`, `cancel_listening`, `ping`). |
| [`partial.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/partial.schema.json) | `partial` | Real-time streaming partial transcript frames sent from Android to Windows. |
| [`final.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/final.schema.json) | `final` | Final speech recognition result text payload sent from Android to Windows. |
| [`error.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/error.schema.json) | `error` | Diagnostic error frame for speech timeouts, audio issues, or transport failures. |
| [`heartbeat.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/heartbeat.schema.json) | `heartbeat` | Keep-alive heartbeat frames sent every 5 seconds over the socket connection. |

---

## Code Generation & Contract Validation

To maintain strict contract traceability and unit testing readiness:

1. **Kotlin (Android)**:
   - Use `kotlinx.serialization` or `Jackson` with JSON schema validation.
   - Model classes in `android/transport/` map directly 1:1 with JSON schemas.
2. **Python (Windows)**:
   - Use `pydantic` or `jsonschema` library for runtime validation.
   - Unit tests use `jsonschema.validate(instance=msg, schema=schema)` to ensure zero protocol drift.

---

## Protocol Test Fixtures (`tests/fixtures/protocol/v1/`)

Sample payload fixtures are provided for contract verification and offline testing:

* [`command_start.json`](file:///home/calur/github/hermes/tests/fixtures/protocol/v1/command_start.json): Sample start listening payload.
* [`command_stop.json`](file:///home/calur/github/hermes/tests/fixtures/protocol/v1/command_stop.json): Sample stop listening payload.
* [`partial_sample.json`](file:///home/calur/github/hermes/tests/fixtures/protocol/v1/partial_sample.json): Sample real-time partial result payload.
* [`final_sample.json`](file:///home/calur/github/hermes/tests/fixtures/protocol/v1/final_sample.json): Sample final result payload.
* [`error_sample.json`](file:///home/calur/github/hermes/tests/fixtures/protocol/v1/error_sample.json): Sample error notification payload.
* [`heartbeat_sample.json`](file:///home/calur/github/hermes/tests/fixtures/protocol/v1/heartbeat_sample.json): Sample heartbeat keep-alive payload.

