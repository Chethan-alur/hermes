# Requirements Traceability Matrix (RTM): Project Hermes

> **Systematic mapping of Functional & Non-Functional Requirements to Subsystems, Protocol Contracts, and Unit/Integration Test Suites.**

---

## 1. Overview & Purpose

This Requirements Traceability Matrix (RTM) ensures complete bi-directional traceability from high-level functional and non-functional requirements down to specific software components, protocol schemas, and test cases.

By linking each requirement to formal JSON schemas in [`protocol/schemas/v1/`](file:///home/calur/github/hermes/protocol/README.md) and automated test suites, Project Hermes enables contract-first development, zero-regression refactoring, and straightforward feature expansion.

---

## 2. Functional Requirements Traceability

| Req ID | Requirement Description | Target Subsystem / Component | Protocol Contract Reference | Test Case ID | Test Strategy & Verification | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **REQ-FUNC-001** | Pixel 8 on-device speech recognition via Android `SpeechRecognizer` | `android/speech` | N/A (Local engine wrapper) | `UT-AND-SPEECH-001` | Mock `SpeechRecognizer` callbacks; verify `SpeechEvent.PartialResult` and `FinalResult` emission without network. | Defined |
| **REQ-FUNC-002** | Zero Cloud Dependency (100% offline speech processing) | `android/speech` | N/A | `UT-AND-OFFLINE-001` | Disable device network adapters in emulator; run speech recognition flow and assert clean output. | Defined |
| **REQ-FUNC-003** | Windows Push-to-Talk (PTT) hotkey activation (Right Ctrl key hold) | `windows/hotkeys` | [`command.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/command.schema.json) (`start_listening`) | `UT-WIN-HOOK-001` | Simulate Win32 `WM_KEYDOWN`/`WM_KEYUP` for `VK_RCONTROL`; assert `start_listening` command generation. | Defined |
| **REQ-FUNC-004** | Windows PTT hotkey release stopping speech recognition | `windows/hotkeys` | [`command.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/command.schema.json) (`stop_listening`) | `UT-WIN-HOOK-002` | Simulate `WM_KEYUP` for `VK_RCONTROL`; assert `stop_listening` command dispatched to transport layer. | Defined |
| **REQ-FUNC-005** | Real-time partial text recognition streaming | `android/speech`, `windows/overlay` | [`partial.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/partial.schema.json) | `UT-PROTO-PARTIAL-001` | Stream partial events over socket mock; verify overlay updates sequence numbers in order. | Defined |
| **REQ-FUNC-006** | Final text transcript delivery on speech completion | `android/speech`, `windows/injector` | [`final.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/final.schema.json) | `UT-PROTO-FINAL-001` | Inject mock final result JSON; verify payload deserialization and delivery to text injector interface. | Defined |
| **REQ-FUNC-007** | Text injection into any active Windows application | `windows/injector` | N/A | `UT-WIN-INJECT-001` | Execute `SendInput` and Clipboard fallbacks against test Notepad process; verify text buffer matches output. | Defined |
| **REQ-FUNC-008** | High-speed USB communication via ADB TCP port forwarding | `android/transport`, `windows/transport` | All Schemas (`v1/*.json`) | `INT-USB-COMM-001` | Establish socket over `adb forward tcp:9999 tcp:9999`; transmit 1000 message payloads and verify 0 loss. | Defined |
| **REQ-FUNC-009** | System and speech error handling & diagnostic alerts | `android/speech`, `windows/overlay` | [`error.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/error.schema.json) | `UT-PROTO-ERR-001` | Trigger simulated engine timeout; assert `error` payload parsed and overlay transitions to ERROR state. | Defined |
| **REQ-FUNC-010** | Transport keep-alive heartbeat monitoring | `android/transport`, `windows/transport` | [`heartbeat.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/heartbeat.schema.json) | `UT-PROTO-HB-001` | Emit periodic heartbeats every 5s; verify transport connection health check flags `READY` state. | Defined |
| **REQ-FUNC-011** | Test mode CLI & simulator for testing protocol concepts and payload playback | `windows/testing` | N/A | `UT-TESTMODE-001` | Defined |

---

## 3. Non-Functional Requirements Traceability

| Req ID | Metric / Requirement | Target Threshold | Target Subsystem | Verification Test Case | Test Method & Benchmark Metric | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **REQ-NFR-001** | End-to-End Latency | **< 500 ms** | Full System Pipeline | `PERF-LATENCY-001` | Measure timestamp difference from `Right-Ctrl UP` event to Win32 `SendInput` invocation. | Defined |
| **REQ-NFR-002** | Windows CPU Utilization | **< 2.0%** (Idle & Active) | `windows/` | `PERF-WIN-CPU-001` | Sample process CPU usage over 10-minute continuous dictation session using Windows Performance Counters. | Defined |
| **REQ-NFR-003** | Android Idle Battery Consumption | **< 2.0% / hour** | `android/` | `PERF-AND-BATTERY-001` | Run Android Foreground Service in idle state for 4 hours; verify battery drop using `dumpsys batterystats`. | Defined |
| **REQ-NFR-004** | Air-Gapped / Network Isolation | 0 external network calls | `android/`, `windows/` | `SEC-AIRGAP-001` | Inspect socket creation and system traffic with Wireshark/tcpdump; assert strictly `127.0.0.1` / ADB sockets. | Defined |
| **REQ-NFR-005** | Transport Auto-Reconnection | **< 2.0 seconds** after reconnect | `windows/transport` | `INT-RECONNECT-001` | Unplug and re-plug USB cable during listening state; verify socket auto-reconnect and state recovery. | Defined |
| **REQ-NFR-006** | Contract Schema Compliance | 100% JSON Schema adherence | `protocol/` | `UT-SCHEMA-VAL-001` | Validate all incoming/outgoing protocol JSON payloads against `protocol/schemas/v1/*.schema.json`. | Defined |

---

## 4. Test Suite Mapping & Unit Test Architecture

### 4.1 Unit Test Hierarchy

```text
tests/
├── unit/
│   ├── protocol/
│   │   ├── test_command_schema.py      # Validates command JSON serialization against schema
│   │   ├── test_partial_schema.py      # Validates partial JSON serialization against schema
│   │   ├── test_final_schema.py        # Validates final JSON serialization against schema
│   │   └── test_error_schema.py        # Validates error JSON serialization against schema
│   ├── windows/
│   │   ├── test_hotkey_manager.py      # Unit tests for Right-Ctrl key listener
│   │   ├── test_text_injector.py       # Unit tests for SendInput and Clipboard fallback
│   │   └── test_state_machine.py       # Unit tests for Windows companion state transitions
│   └── android/
│       ├── SpeechEngineTest.kt         # Unit tests for SpeechEngine interface & mocks
│       ├── SessionControllerTest.kt    # Unit tests for Android speech session lifecycle
│       └── TransportServerTest.kt      # Unit tests for TCP socket frame parsing
├── integration/
│   ├── test_usb_transport.py           # Integration tests for ADB socket forwarding
│   └── test_reconnection_flow.py       # Integration tests for cable unplug/replug handling
└── performance/
    └── test_latency_benchmarks.py     # End-to-end latency measurement scripts (< 500 ms)
```

---

## 5. Traceability Maintenance Protocol

When adding new features (e.g. LLM post-processing, custom voice commands, BLE transport):
1. **Assign REQ ID**: Add new functional requirement (`REQ-FUNC-XXX`) to `docs/RTM.md`.
2. **Update Protocol Schema**: If message structure changes, increment schema version in `protocol/schemas/v2/`.
3. **Bind Component & Test**: Map target code module and define matching unit test suite ID (`UT-XXX`).
4. **Run Verification**: Ensure 100% compliance across `protocol/` schemas before merging code updates.
