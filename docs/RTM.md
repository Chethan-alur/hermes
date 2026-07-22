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
| **REQ-FUNC-003** | Windows Push-to-Talk (PTT) hotkey activation (Right Ctrl key hold) | `windows/hotkeys` | [`command.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/command.schema.json) (`start_listening`) | `UT-WIN-HOOK-001` | Simulate Win32 `WM_KEYDOWN`/`WM_KEYUP` for `VK_RCONTROL`; assert `start_listening` command generation. Python daemon aligned: `main.py` `load_config()` now reads the config `hotkeys` (VK 163 = Right Ctrl) and `HotkeyManager` matches `Key.ctrl_r` (previously hardcoded `f12`). | Defined |
| **REQ-FUNC-004** | Windows PTT hotkey release stopping speech recognition | `windows/hotkeys` | [`command.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/command.schema.json) (`stop_listening`) | `UT-WIN-HOOK-002` | Simulate `WM_KEYUP` for `VK_RCONTROL`; assert `stop_listening` command dispatched to transport layer. | Defined |
| **REQ-FUNC-005** | Real-time partial text recognition streaming | `android/speech`, `windows/overlay` | [`partial.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/partial.schema.json) | `UT-PROTO-PARTIAL-001` | Stream partial events over socket mock; verify overlay updates sequence numbers in order. The consuming overlay is realised by the dictation HUD (REQ-FUNC-014) in `windows/hermes_hotkey.ps1`. | Defined |
| **REQ-FUNC-006** | Final text transcript delivery on speech completion | `android/speech`, `windows/injector` | [`final.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/final.schema.json) | `UT-PROTO-FINAL-001`, `UT-AND-PARTIAL-001` | Inject mock final result JSON; verify payload deserialization and delivery to text injector interface. Transcript integrity across mid-utterance pauses: some on-device recognizers reset their partial hypothesis at a pause (empty/shorter unrelated partial) instead of committing the chunk via onResults; `AndroidSpeechEngine.partialContinues` detects the reset so the previous chunk is committed to the accumulated transcript and pre-pause speech is never dropped from the final (`UT-AND-PARTIAL-001`). | Defined |
| **REQ-FUNC-007** | Text injection into any active Windows application | `windows/injector` | N/A | `UT-WIN-INJECT-001` | Execute `SendInput` and Clipboard fallbacks against test Notepad process; verify text buffer matches output. | Defined |
| **REQ-FUNC-008** | High-speed USB communication via **USB tethering** (RNDIS/NCM `usb0` interface; no ADB, so developer options can stay off) | `android/transport`, `windows/transport` | All Schemas (`v1/*.json`) | `INT-USB-COMM-001` | Enable USB tethering; establish socket to the phone's `usb0` IP:9999; transmit 1000 message payloads and verify 0 loss. | Updated |
| **REQ-FUNC-009** | System and speech error handling & diagnostic alerts | `android/speech`, `windows/overlay` | [`error.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/error.schema.json) | `UT-PROTO-ERR-001` | Trigger simulated engine timeout; assert `error` payload parsed and overlay transitions to ERROR state. The ERROR-state presentation is realised by the dictation HUD (REQ-FUNC-014). Error `code` enum reconciled with the codes emitted by Android `getErrorCodeString` (see REQ-NFR-006). | Defined |
| **REQ-FUNC-010** | Transport keep-alive heartbeat monitoring | `android/transport`, `windows/transport` | [`heartbeat.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/heartbeat.schema.json) | `UT-PROTO-HB-001` | Emit periodic heartbeats every 5s; verify transport connection health check flags `READY` state. | Defined |
| **REQ-FUNC-011** | Test mode CLI & simulator for testing protocol concepts and payload playback | `windows/testing` | N/A | `UT-TESTMODE-001` | Defined |
| **REQ-FUNC-012** | User-selectable transports (Wi-Fi / Mobile data / USB tethering) with availability-gated, battery-aware listening | `android/transport`, `android` (UI) | N/A | `UT-AND-TRANSPORT-001`, `UT-AND-USBIFACE-001` | Toggle each transport switch; assert the service opens/closes its listener to match (selection ∩ live availability), binds `usb0` when USB-only and `0.0.0.0` when a network transport is active. Durability: `reconcile()` re-detects the USB tether on every run (via `isUsbTetherInterfaceName`, `UT-AND-USBIFACE-001`) so a missed `ACTION_USB_STATE` broadcast self-heals on the next Wi-Fi/cellular network callback instead of stranding the listener idle. | Defined |
| **REQ-FUNC-013** | Bluetooth headset microphone support for dictation (route capture to a connected HFP/SCO or LE-Audio headset) | `android/speech` | N/A (audio routing) | `UT-AND-BTMIC-001` | Given available communication devices, assert the preferred Bluetooth input is selected (LE-Audio over classic SCO, none when absent); on-device empirical check that speaking into a paired headset yields a transcript. | Defined |
| **REQ-FUNC-017** | Configurable start/stop audible cue volume (0..100, 0 = off) via an in-app slider, quiet by default for office use | `android/speech`, `android` (UI) | N/A (local audio) | `UT-AND-CUE-001` | `AndroidSpeechEngine.playCue` reads `KEY_CUE_VOLUME` (default 35, down from a fixed 80), rebuilds the `ToneGenerator` when the level changes (its volume is fixed at construction) and skips the cue entirely at 0; a `SeekBar` in `MainActivity` persists the level. Manual on-device verification. | Defined |
| **REQ-FUNC-016** | Windows client transport-endpoint selection: choose the phone endpoint (host IP) from a tray **Transport** submenu of named endpoints, switching live (drop socket + reconnect) without editing config or restarting; optional mDNS auto-discovery of `_hermes._tcp` on the LAN | `windows` (tray client), `android/transport` (mDNS advertise) | Reuses the existing TCP transport (no new contract); endpoints in `hermes.config.json` (`transports` map) | `UT-WIN-TRANSPORT-001` | `Set-Transport` reassigns `$HOST_IP`, persists, drops the socket and resets backoff so `Ensure-Connected` redials the new host; menu items carry the host in `.Tag` to avoid closure capture. Verified live: switched to WireGuard and connected (laptop 10.10.0.10 ↔ phone 10.10.0.40:9999 over the tunnel). mDNS discovery (Android `NsdManager` advertise + Windows browse) covers Wi-Fi/tether LANs, not the routed WireGuard tunnel (static IP there). Implemented: Android advertises `_hermes._tcp` via `NsdManager` (`nsdServiceName`, unit-tested); the tray queries mDNS first (`Resolve-HermesMdns`, raw DNS-SD with the QU bit) then fails over through the configured endpoints (`Get-ConnectCandidates` → `Ensure-Connected` tries each, first to answer on 9999 wins). Connection-state UX: the tray icon is **green only when connected** (grey disconnected, red dictating) via `Update-TrayIcon`, and the overlay shows a **"Not connected"** state instead of "Listening" when offline. Manual verification on the Windows host (`pwsh` unavailable under WSL). | Defined |
| **REQ-FUNC-015** | On-device transcript proofreading: clean grammar/punctuation on the final transcript before delivery, using Gemini Nano via ML Kit GenAI (AICore), best-effort with fallback to the raw transcript | `android/speech` | Reuses [`final.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/final.schema.json) (cleaned text in the same `final` frame; no new contract) | `UT-AND-PROOFREAD-001` | `TranscriptProofreader` (ML Kit `genai-proofreading`, `InputType.VOICE`) checks feature status, downloads the model on demand, and runs on-device inference on the assembled transcript in `emitFinal`; on unavailable/timeout/error it falls back to the raw text so dictation never breaks, gated by the `proofread` preference. Framework-backed (AICore) so verified empirically on-device (latency + quality); the fallback path keeps output correct when the model is absent. | Defined |
| **REQ-FUNC-014** | Windows dictation overlay (HUD): a non-focus-stealing floating window that shows the listening indicator, the live streaming partial transcript as it grows, and final-transcript confirmation at injection | `windows/overlay` (realised in `windows/hermes_hotkey.ps1`) | Reuses [`partial.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/partial.schema.json), [`final.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/final.schema.json), [`error.schema.json`](file:///home/calur/github/hermes/protocol/schemas/v1/error.schema.json) (no new contract) | `UT-WIN-OVERLAY-001` | Rendered as a `WS_EX_NOACTIVATE \| WS_EX_TOOLWINDOW \| WS_EX_TOPMOST` layered WinForms window shown with `SW_SHOWNOACTIVATE`, so it never becomes foreground and never disturbs `$targetHwnd` capture / paste. Consumes the existing `partial`/`final`/`error` frames already handled in `Process-HermesLine`. Manual verification on the Windows host (WinForms UI; `pwsh` unavailable under WSL, so no automated PowerShell test): bar appears bottom-centre on dictation start, the transcript grows with partial results, the final text is confirmed green and still pasted into the correct window, and focus/typing in the target editor is never interrupted. | Defined |

---

## 3. Non-Functional Requirements Traceability

| Req ID | Metric / Requirement | Target Threshold | Target Subsystem | Verification Test Case | Test Method & Benchmark Metric | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **REQ-NFR-001** | End-to-End Latency | **< 500 ms** | Full System Pipeline | `PERF-LATENCY-001` | Measure timestamp difference from `Right-Ctrl UP` event to Win32 `SendInput` invocation. | Defined |
| **REQ-NFR-002** | Windows CPU Utilization | **< 2.0%** (Idle & Active) | `windows/` | `PERF-WIN-CPU-001` | Sample process CPU usage over 10-minute continuous dictation session using Windows Performance Counters. | Defined |
| **REQ-NFR-003** | Android Idle Battery Consumption | **< 2.0% / hour** | `android/` | `PERF-AND-BATTERY-001` | Run Android Foreground Service in idle state for 4 hours; verify battery drop using `dumpsys batterystats`. | Defined |
| **REQ-NFR-004** | Air-Gapped / Network Isolation (**USB-only mode**) | 0 external network calls when only USB is selected | `android/`, `windows/` | `SEC-AIRGAP-001` | With only USB tethering selected, assert the server binds solely to the `usb0` address (not `0.0.0.0`) and makes 0 external calls. Wi-Fi/mobile transports are opt-in and intentionally relax this (traffic is carried over the user's WireGuard tunnel). | Updated |
| **REQ-NFR-005** | Transport Auto-Reconnection | **< 2.0 seconds** after reconnect | `windows/transport` | `INT-RECONNECT-001` | Unplug and re-plug USB cable during listening state; verify socket auto-reconnect and state recovery. | Defined |
| **REQ-NFR-006** | Contract Schema Compliance | 100% JSON Schema adherence | `protocol/` | `UT-SCHEMA-VAL-001` | Validate all incoming/outgoing protocol JSON payloads against `protocol/schemas/v1/*.schema.json`. `error.schema.json` `code` enum expanded to the union of codes emitted by Android `getErrorCodeString` so real error frames validate. | Defined |

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
