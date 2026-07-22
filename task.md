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

## Track F — Transcript integrity + durable transport (REQ-FUNC-006, REQ-FUNC-012) [live debugging]
Plan: two Android fixes found via live use, fixed contract-first, one APK rebuild.
- [x] F1. RTM notes: REQ-FUNC-006 (transcript survives mid-utterance pauses), REQ-FUNC-012 (reconcile self-heals stale USB state)
- [x] F2. `SpeechEngine.kt`: pure `partialContinues(prev,next)` helper + commit-on-regression in `onPartialResults` (recognizer resets partial at pauses -> commit prior chunk so pre-pause speech is not lost)
- [x] F3. `TransportServerService.kt`: `reconcile()` calls `refreshUsbState()` first (self-heal missed ACTION_USB_STATE); extract pure `isUsbTetherInterfaceName()`
- [x] F4. JUnit tests: `PartialAccumulationTest` 6/6 + `UsbTetherInterfaceTest` 2/2 (BUILD SUCCESSFUL)
- [x] F5. `task android:build` + `adb install -r` OK; app relaunched, listener bound, tray reconnected
- [ ] F6. Live verify: paused PTT dictation preserves all speech; USB replug -> listener + route both recover without app restart

## Track G — On-device transcript proofreading (Gemini Nano / ML Kit GenAI) (REQ-FUNC-015) [spike]
Plan: clean grammar/punctuation on the final transcript on-device before delivery; best-effort,
falls back to raw text on unavailable/timeout/error. Pixel 8 has AICore (Gemini Nano) present.
- [x] G1. RTM REQ-FUNC-015
- [x] G2. `app/build.gradle.kts`: add `com.google.mlkit:genai-proofreading:1.0.0-beta1` (+ `-Xskip-metadata-version-check`)
- [x] G3. `TranscriptProofreader.kt`: wrap Proofreader (VOICE/ENGLISH); ListenableFuture checkFeatureStatus + downloadFeature; runInference with timeout + fallback to original
- [x] G4. `SpeechEngine.kt`: `KEY_PROOFREAD` pref (default on); `emitFinal` -> `deliverFinal`; close on destroy. When feature unavailable, proofread() short-circuits (no added latency)
- [x] G5. Build OK; unit tests 12/12; `adb install -r` OK, app relaunched, listener bound
- [ ] G6. BLOCKED: on THIS Pixel 8, AICore reports the Proofreading GenAI feature (614) `FEATURE_NOT_FOUND` (error 606) — not provisioned on this device. Integration falls back to raw text (dictation unaffected, zero added latency). Would activate automatically if a device/AICore build offers the feature (Pixel 8 Pro / Pixel 9-class). Decision pending: provision attempt vs cloud LLM vs accept.

## Track H — Windows transport selection + mDNS auto-discovery (REQ-FUNC-016) [user request]
Plan: stop hand-editing the config host; pick the transport endpoint from the tray, and later
auto-discover the phone on the LAN.
- [x] H1. RTM REQ-FUNC-016
- [x] H2. `hermes_hotkey.ps1`: `transports` config map; tray **Transport** submenu (named endpoints); `Set-Transport` live switch (drop socket + reset backoff -> Ensure-Connected redials); persisted
- [x] H2b. Runtime IP editing from the tray (no JSON edit): **Add endpoint...**, **Edit current endpoint...**, **Remove current endpoint** via InputBox; persists + reconnects. Enables different networks.
- [x] H3. Deployed + restarted; verified **WireGuard connected** (laptop 10.10.0.10 <-> phone 10.10.0.40:9999 over tunnel). Picker works for all endpoints incl. WireGuard.
- [ ] H4. Android: advertise `_hermes._tcp` via `NsdManager` when serving (mDNS)
- [ ] H5. Windows: mDNS discovery of `_hermes._tcp` (LAN only; picker is the fallback; does NOT cross WireGuard)
Note: repo `windows/hermes_hotkey.ps1` picker change is UNCOMMITTED.

## Track I — Configurable start/stop cue volume (REQ-FUNC-017) [user request: too loud for office]
- [x] I1. RTM REQ-FUNC-017
- [x] I2. `SpeechEngine.kt`: `KEY_CUE_VOLUME` pref (default 35, was fixed 80; 0=off); `playCue` rebuilds ToneGenerator on level change
- [x] I3. Android UI: `SeekBar` (seek_cue_volume) + label in MainActivity/activity_main.xml/strings
- [ ] I4. Build APK + install; verify the slider softens/silences the cue

## Track J — Connection-state UX + mDNS-first failover [user bugfixes]
- [x] J1. Tray icon: green=connected, grey=disconnected, red=dictating (`Update-TrayIcon`) — deployed
- [x] J2. Overlay: `Disconnected` state; `Start-Dictation` shows "Not connected" (no false "Listening") — deployed
- [x] J3. Windows: `Resolve-HermesMdns` (raw DNS-SD, QU bit) + `Try-Connect($host)` + `Get-ConnectCandidates` + `Ensure-Connected` failover; mDNS tray toggle — deployed (log shows new connect cycle)
- [x] J4. Android NSD advertise (`_hermes._tcp`) + `nsdServiceName` helper + JUnit (5/5). Installed; phone advertises "Hermes (Pixel 8) _hermes._tcp:9999". Windows mDNS query verified working (discovered the phone).
- [x] J5. RTM REQ-FUNC-016 extended; Windows tray + Android APK deployed.
- Config simplified per user: named `transports` map -> plain `hosts` IP list (tray "Server" submenu; Add/Edit/Remove IP; auto-migrates old config). mDNS now returns ALL A records (multi-homed).
- KNOWN ISSUE (not a bind-family bug): wildcard serving refuses the **USB-tether** IP due to an Android tether reverse-routing/source-address quirk (SYN-ACK egresses the default network) — WireGuard/Wi-Fi over the same wildcard connect fine; USB needs USB-only (Specific bind). `ServerSocketChannel.open(INET)` fix needs compileSdk 35 (only 34 installed). Deferred.

## Track K — Reverse-connect transport mode (phone dials the PC) (REQ-FUNC-018) [user request]
Plan: the full-tunnel office VPN enforces stateful client isolation — laptop→phone is impossible at
every phone address (VPN pool 10.212.134.150, NAT 10.141.1.254), but **phone→laptop 10.141.1.47
connects** (phone NAT'd to 10.141.1.254; empirically verified this session). So invert the TCP
direction: the phone dials the Windows client, which listens. Data flow (phone→PC transcripts,
PC→phone commands) and all v1 frames are unchanged — no protocol/schema change (Rule 5 steps 3–4 =
no change, documented). Governance: RTM REQ-FUNC-018; Android pure helper unit-tested; Windows UI
manually verified on the host.
- [x] K1. RTM REQ-FUNC-018 + task.md track
- [x] K2. `TransportPrefs.kt`: `reverse_connect` (bool), `reverse_hosts` (string), `reverse_port` (int, 9999) + pure `parseReverseHosts` helper
- [x] K3. `TransportServerService.kt`: `Plan` sealed type (Idle/Serve/Dial); `reconcile` chooses Dial when reverse-connect on + hosts set + a network is up; `dialLoop` connects out and runs `handleClientConnection` with backoff; no mDNS in dial mode
- [x] K4. Android UI: `switch_reverse` + PC-host `EditText` in MainActivity/activity_main.xml/strings; persist + `reconfigureService`
- [x] K5. JUnit `UT-AND-REVERSEHOSTS-001` (`parseReverseHosts`): comma/space/semicolon split, trim, de-dup, ip:port tolerated — 5/5 pass
- [x] K6. `hermes_hotkey.ps1`: config `listen`/`listenPort`; `$script:ListenEnabled`/`$script:ListenPort`; tray toggle "Listen mode (phone dials in)" (`Set-ListenEnabled`/`Update-ListenCheck`); `Ensure-Listening` (TcpListener + `Pending()`/`AcceptTcpClient` -> the three socket globals); `Ensure-Connected` branches to it; `Stop-Listener`; disconnect/cleanup listener-aware. Structural check: braces 384/384, parens 660/660, here-strings 2/2
- [x] K7. `install_hermes.ps1`: idempotent inbound TCP firewall rule for the listen port (elevated, best-effort) + preserve `listen`/`listenPort` across reinstalls
- [x] K8. Build: Android unit tests 20/20 (incl. parseReverseHosts 5/5) + `assembleDebug` green; `adb install -r` OK
- [x] K9. Live verify Android dial-out against a host TCP listener: phone dialed 10.141.1.47:9999 over the office VPN (peer 10.141.1.254), sent the heartbeat, honoured `start_listening` (ListeningStarted), replied with a `status` frame. Full v1 protocol confirmed over the inverted connection.
- [ ] K10. (Manual, Windows host — `pwsh` unavailable under WSL) deploy tray, enable Listen mode, enable phone reverse-connect (host 10.141.1.47), confirm the phone dials in and PTT dictation pastes; firewall allowed

Note: canonical test invocation is `python3 -m unittest discover -s tests -p "test_*.py"` (all 13 pass).
Discovering from `-s tests/unit` fails spuriously — `tests/unit/windows/` shadows the real top-level `windows/` package. Use `-s tests`.
