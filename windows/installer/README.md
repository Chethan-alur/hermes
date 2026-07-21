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

## Alternative: self-extracting Setup.exe (IExpress — no Inno Setup)

If you do not have Inno Setup, you can build a self-extracting `Setup.exe` using **IExpress**,
which ships with every Windows install. It bundles `install_hermes.ps1` and its payload files
(`hermes_hotkey.ps1`, `hermes_launcher.vbs`, `hermes.config.json`); when run, it extracts them to a
temporary folder and executes `install_hermes.ps1` unchanged.

From a **Windows** shell at the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File windows\installer\build_sfx.ps1
```

Or via Task:

```bash
task windows:installer:sfx
```

Output: **`windows/dist/ProjectHermes-Setup.exe`** (same location as the Inno build).

The build recipe is `windows/installer/hermes.sed` (an IExpress directive with a `__STAGEDIR__`
placeholder); `build_sfx.ps1` stages the payload into a local temp folder — IExpress cannot read
sources over a UNC `\\wsl$` path — substitutes the placeholder, invokes `iexpress.exe /N /Q`, and
copies the result into `windows/dist`. Trade-offs versus the Inno build: no Add/Remove-Programs
uninstaller entry and a plainer extraction UI; to remove it, use `windows/uninstall_hermes.ps1`.

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
