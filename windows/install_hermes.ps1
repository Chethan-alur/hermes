# Project Hermes - Windows installer
# ------------------------------------------------------------------------------
# Copies the companion to %LOCALAPPDATA%\ProjectHermes (a stable Windows location,
# independent of WSL), registers it to auto-start hidden at logon, adds a Start Menu
# shortcut, and launches it into the system tray.
#
# Run from a Windows PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File windows\install_hermes.ps1
# ------------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

$srcDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$destDir = Join-Path $env:LOCALAPPDATA 'ProjectHermes'

Write-Host "Installing Project Hermes to $destDir ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

# Refresh the program files. For the config, MERGE rather than overwrite: keep the user's
# host/port (now a USB-tether / Wi-Fi / WireGuard IP under the current transport) but
# (re)apply the shipped default mode (PushToTalk) and hotkey (Right Ctrl / VK 163). This
# fixes a stale hotkey (e.g. an old [123]=F12) without clobbering the connection setting.
Copy-Item (Join-Path $srcDir 'hermes_hotkey.ps1')   (Join-Path $destDir 'hermes_hotkey.ps1')   -Force
Copy-Item (Join-Path $srcDir 'hermes_launcher.vbs') (Join-Path $destDir 'hermes_launcher.vbs') -Force
$srcCfg   = Join-Path $srcDir  'hermes.config.json'
$destCfg  = Join-Path $destDir 'hermes.config.json'
$destHost = '127.0.0.1'; $destPort = 9999
# Default the connection to whatever the source (repo) config specifies -- e.g. the phone's
# current USB-tether IP -- so a fresh install does not silently fall back to 127.0.0.1 and hang.
if (Test-Path $srcCfg) {
    try {
        $srcJson = Get-Content $srcCfg -Raw | ConvertFrom-Json
        if ($srcJson.host) { $destHost = [string]$srcJson.host }
        if ($srcJson.port) { $destPort = [int]$srcJson.port }
    } catch {}
}
# A prior installation's setting then wins, so reinstalling never clobbers a host the user changed.
if (Test-Path $destCfg) {
    try {
        $existing = Get-Content $destCfg -Raw | ConvertFrom-Json
        if ($existing.host) { $destHost = [string]$existing.host }
        if ($existing.port) { $destPort = [int]$existing.port }
    } catch {}
}
([ordered]@{ mode = 'PushToTalk'; host = $destHost; port = $destPort; hotkeys = @(163) } | ConvertTo-Json) |
    Set-Content -Path $destCfg -Encoding UTF8

$launcher = Join-Path $destDir 'hermes_launcher.vbs'
$wsh      = New-Object -ComObject WScript.Shell
$startup  = [Environment]::GetFolderPath('Startup')
$programs = [Environment]::GetFolderPath('Programs')

function New-HermesShortcut($linkPath) {
    $lnk = $wsh.CreateShortcut($linkPath)
    $lnk.TargetPath       = 'wscript.exe'
    $lnk.Arguments        = '"' + $launcher + '"'
    $lnk.WorkingDirectory = $destDir
    $lnk.IconLocation     = "$env:SystemRoot\System32\SndVol.exe, 0"
    $lnk.Description       = 'Project Hermes voice dictation companion'
    $lnk.Save()
}

$startupLnk  = Join-Path $startup  'Project Hermes.lnk'
$programsLnk = Join-Path $programs 'Project Hermes.lnk'
New-HermesShortcut $startupLnk
New-HermesShortcut $programsLnk

# Stop any currently running instance, then launch the freshly installed one.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" 2>$null |
    Where-Object { $_.CommandLine -like '*hermes_hotkey.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process 'wscript.exe' -ArgumentList ('"' + $launcher + '"')

Write-Host ""
Write-Host "Project Hermes installed and started in the system tray." -ForegroundColor Green
Write-Host "  Auto-start at logon : $startupLnk" -ForegroundColor Gray
Write-Host "  Start Menu shortcut : $programsLnk" -ForegroundColor Gray
Write-Host "  Program files       : $destDir" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: the Android app must be running and reachable at the host:port set in" -ForegroundColor DarkYellow
Write-Host "hermes.config.json (USB-tether / Wi-Fi / WireGuard IP) for the tray to go active;" -ForegroundColor DarkYellow
Write-Host "the daemon retries the connection automatically." -ForegroundColor DarkYellow
