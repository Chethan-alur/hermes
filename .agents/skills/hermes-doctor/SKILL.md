---
name: hermes-doctor
description: End-to-end diagnostics for the running Hermes system (Android + Windows) for AI coding agents — health check, live runtime status, unified cross-device log view, active pipeline probe, and a one-shot diagnostic report bundle.
---

# Hermes Doctor Skill

This skill gives an AI coding agent a single, structured surface for debugging the **running**
Hermes pipeline end-to-end (Android phone → TCP:9999 → Windows companion). It only *reads*
runtime state; it makes no changes to the product (the sole exception is the opt-in
`--fix-forward` flag on `probe`, which runs `adb forward`).

It resolves the transport endpoint the same way `windows/main.py` does:
`HERMES_HOST`/`HERMES_PORT` env → `windows/hermes.config.json` → `127.0.0.1:9999`.
The Android log/state checks require `adb`; when `adb` or the phone is unavailable the skill
degrades to a Windows-only view instead of failing.

> WSL caveat: a green TCP probe from WSL (via a WSL-side `adb forward tcp:9999`) does **not**
> prove the Windows companion can reach the phone — the companion uses Windows loopback / the
> tether IP, a different network namespace. The tool states this explicitly.

## Usage Instructions

Run the diagnostics helper script:

```bash
python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py doctor
```

### Subcommands

- Health check (processes, adb/device, TCP liveness, config sanity):
  ```bash
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py doctor
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py doctor --json --strict
  ```
- Live runtime status (what Hermes is doing right now — serving/transport state, recent pipeline state):
  ```bash
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py status
  ```
- Unified, timestamp-ordered log view across `windows.log`, `windows/hermes.log`, and `adb logcat`:
  ```bash
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py logs --lines 200 --since 10m
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py logs --follow
  ```
- Active end-to-end pipeline probe (`ping`→heartbeat, `simulate_speech` causal trace):
  ```bash
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py probe --simulate
  ```
- One-shot diagnostic report bundle (writes JSON + Markdown an agent can read in one shot):
  ```bash
  python3 .agents/skills/hermes-doctor/scripts/hermes_doctor.py report
  ```

### Common options

- `--host` / `--port` — override the resolved endpoint.
- `--adb PATH` — path to the `adb` binary (default: `HERMES_ADB` env → SDK platform-tools → `adb` on PATH).
- `--json` — machine-readable output for agent consumption.
- `--skip-android` — skip all adb/logcat checks (Windows-only view).
- `--timeout SECONDS` — socket timeout (default 5).

### Taskfile shortcuts

```bash
task doctor
task doctor:status
task doctor:logs -- --lines 200
task doctor:probe
task doctor:report
```
