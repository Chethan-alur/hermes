# Project Hermes — packaged Windows installer

Builds a standalone **`ProjectHermes-Setup.exe`** with [Inno Setup 6](https://jrsoftware.org/isdl.php).
It is a **per-user** installer (no admin required): it installs the companion to
`%LOCALAPPDATA%\ProjectHermes`, auto-starts it hidden at logon (system-tray app), adds a
Start-menu shortcut, and writes/merges `hermes.config.json`.

## Prerequisites (one-time, on Windows)
- Install **Inno Setup 6** from https://jrsoftware.org/isdl.php.
- The compiler is `ISCC.exe`, typically at `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`.
  Add that folder to your `PATH`, or use the full path in the build command below.

## Build the Setup.exe
From a **Windows** shell at the repo root:

```powershell
# If ISCC.exe is on PATH:
ISCC.exe windows\installer\hermes.iss

# Otherwise, full path:
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\installer\hermes.iss
```

Or via Task (from a shell where `powershell.exe` and `ISCC.exe` are reachable):

```bash
task windows:installer:build
```

Output: **`windows/dist/ProjectHermes-Setup.exe`**.

## Install / run
Double-click `ProjectHermes-Setup.exe` and follow the wizard (tick *"Start Project Hermes now"*
on the last page). It will:
- install to `%LOCALAPPDATA%\ProjectHermes`,
- register a **logon** auto-start shortcut and a **Start-menu** shortcut,
- **merge** `hermes.config.json`: it **keeps** any existing `host`/`port` (your USB-tether /
  Wi-Fi / WireGuard IP) and **sets** `mode = PushToTalk` and `hotkeys = [163]` (Right Ctrl).

The daemon runs in the system tray; right-click it to switch Toggle / Push-to-Talk or exit.
For the tray to go active, the Android app must be running and reachable at the `host:port`
in the config.

## Uninstall
Use **Settings → Apps → Project Hermes → Uninstall** (or the entry in Apps & Features).
The uninstaller stops the running daemon and removes the files and shortcuts.

## Notes
- The bundled `hermes_setup_helper.ps1` performs the stop-old-daemon and config-merge steps.
- The no-dependency PowerShell installer (`windows/install_hermes.ps1`) remains available as an
  alternative that needs no Inno Setup.
- `windows/dist/` (the built `.exe`) is git-ignored.
