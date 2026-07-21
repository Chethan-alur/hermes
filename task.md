# Living Task Checklist — AI-agent debugging capability (`hermes-doctor`)

Plan: dev-time diagnostics skill for AI coding agents + two contract-first bug fixes.
Governance: skill is REQ-exempt (dev tooling); the two fixes follow AGENTS.md Rule 5.

## Track A — `hermes-doctor` diagnostics skill (REQ-exempt tooling)
- [x] A1. Create `.agents/skills/hermes-doctor/SKILL.md`
- [x] A2. Create `.agents/skills/hermes-doctor/scripts/hermes_doctor.py` (subcommands: doctor, status, logs, probe, report)
- [x] A3. Wire `doctor`, `doctor:status`, `doctor:logs`, `doctor:probe`, `doctor:report` into `Taskfile.yaml` AND `Taskfile.yml`
- [x] A4. Add `.task/hermes-doctor/` to `.gitignore`

## Track B — Fix hotkey config bug (REQ-FUNC-003)
- [x] B1. Annotate RTM REQ-FUNC-003 (`UT-WIN-HOOK-001`) for Python-daemon config alignment
- [x] B2. Extend `tests/unit/windows/test_hotkey.py` (real `_is_target_key` Right-Ctrl + `load_config` hotkey)
- [x] B3. `windows/main.py`: `load_config` reads `hotkeys`; pass resolved key to `HotkeyManager`
- [x] B4. `windows/hotkeys/hotkey_manager.py`: match `Key.ctrl_r` / VK 163 in `_is_target_key`

## Track C — Fix error-enum drift (REQ-NFR-006, REQ-FUNC-009) — Approach A
- [x] C1. Annotate RTM REQ-NFR-006 / REQ-FUNC-009 for enum reconciliation
- [x] C2. `docs/HLD.md` — no canonical enum list exists (only one example payload); no change needed
- [x] C3. Expand `code` enum in `protocol/schemas/v1/error.schema.json` to the union (13 codes)
- [x] C4. Add fixtures for previously-orphan codes in `tests/fixtures/protocol/v1/` (network_timeout, recognizer_busy, insufficient_permissions)
- [x] C5. Register new fixtures in `test_schemas.py` + `validate_protocol.py`; add drift-guard test tying Kotlin source to schema

## Verification (Rule 9/10)
- [x] V1. `python3 -m py_compile` all modified Python — OK
- [x] V2. test-runner protocol + unit suites green; `validate-protocol --all` green incl. new fixtures
- [x] V3. `test_hotkey.py` green (7/7); Red→Green confirmed
- [x] V4. doctor/status/logs/probe/report + `logs --follow` run in Windows-only mode; no crashes; `--json` valid
- [x] V5. `doctor` → both `config.hotkey` and `config.error_enum` now report ✅ (no drift)
- [ ] V6. (Manual, Windows host — cannot run in WSL) Right-Ctrl PTT with real pynput; `task test:e2e` with the phone connected. Logic covered by fake-keyboard unit tests.

## Track D — Bluetooth headset microphone (REQ-FUNC-013) [emergent from live debugging]
- [x] D1. RTM REQ-FUNC-013 + HLD microphone-routing note
- [x] D2. `SpeechEngine`: route capture to BT headset via `setCommunicationDevice` (LE-Audio > SCO), warm-up, clear on every session-terminal path
- [x] D3. Pure `preferredBluetoothInputType` helper + JUnit test (new `android/app/src/test/` source set) — 4/4 pass
- [x] D4. Build (`assembleDebug`) + install new APK + relaunch (serving on ncm0, prefer_offline=true)
- [ ] D5. Live empirical verify with the Bluetooth headset (Rule 9) — pending user test

## Track E — Windows dictation overlay / HUD (REQ-FUNC-014) [user request]
Plan: realise the `windows/overlay` HUD (HLD §5.1, M6) — a non-focus-stealing bottom-centre bar
showing the live listening indicator, the running partial transcript, and the final transcript at
injection. Realised in the WinForms tray client; reuses existing partial/final/error frames (no
protocol change). Governance: RTM/HLD updated (Rules 1/3/4); no contract/fixture change (Rule 5
steps 3–4 = no change needed, documented).
- [x] E1. RTM REQ-FUNC-014 + notes on REQ-FUNC-005 / REQ-FUNC-009 (overlay now realised)
- [x] E2. HLD §5.1 overlay-realisation note + Milestone M6 marked realised
- [x] E3. `windows/hermes_hotkey.ps1`: `Hermes.OverlayForm` C# subclass (no-activate / tool-window / topmost / layered / transparent) via `Add-Type`
- [x] E4. `windows/hermes_hotkey.ps1`: `Initialize-Overlay` + `Show-Overlay` / `Set-OverlayText` / `Set-OverlayFinal` / `Set-OverlayInfo` / `Set-OverlayError` / `Hide-Overlay` / `Update-OverlayBounds` (paint dot + state + wrapped transcript; pulse + fade timer)
- [x] E5. Wire overlay into `Start-Dictation`, `Stop-Dictation`, `Process-HermesLine` (partial/final/error), disconnect path, and cleanup
- [x] E6. Tray toggle "Show dictation overlay" + `overlay` field in `Load-Config` / `Save-Config` (default true); guard all overlay calls on `$script:OverlayEnabled`
- [x] E7. Verify: Python unit + protocol suites green (17 tests OK; fixtures pass); RTM lists REQ-FUNC-014. Added `-Preview` dev mode (phone-free overlay self-test) reusing the real overlay functions.
- [ ] E8. (Manual, Windows host — `pwsh` unavailable under WSL) run `hermes_hotkey.ps1 -Preview` and a live PTT; confirm bar shows/grows/finalises, paste still lands in the correct window, focus never stolen, toggle works

Note: canonical test invocation is `python3 -m unittest discover -s tests -p "test_*.py"` (all 13 pass).
Discovering from `-s tests/unit` fails spuriously — `tests/unit/windows/` shadows the real top-level `windows/` package. Use `-s tests`.
