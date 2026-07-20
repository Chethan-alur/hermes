# Project Hermes - installer helper (invoked by the Inno Setup installer, hermes.iss).
#   -Mode postinstall : stop any running daemon, then merge the config (keep host/port,
#                       (re)set mode=PushToTalk and hotkeys=[163] = Right Ctrl).
#   -Mode stop        : just stop the running daemon (used on uninstall).
param(
    [ValidateSet('postinstall', 'stop')] [string]$Mode = 'postinstall',
    [string]$AppDir = $PSScriptRoot
)
$ErrorActionPreference = 'SilentlyContinue'

# Stop any running Hermes daemon (old code) so the new install takes over cleanly.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*hermes_hotkey.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

if ($Mode -eq 'postinstall') {
    # Merge hermes.config.json: preserve the user's host/port (USB-tether / Wi-Fi /
    # WireGuard IP), and (re)apply the shipped default mode + hotkey. This fixes a stale
    # hotkey without wiping the connection setting.
    $cfg = Join-Path $AppDir 'hermes.config.json'
    $destHost = '127.0.0.1'; $destPort = 9999
    if (Test-Path $cfg) {
        try {
            $existing = Get-Content $cfg -Raw | ConvertFrom-Json
            if ($existing.host) { $destHost = [string]$existing.host }
            if ($existing.port) { $destPort = [int]$existing.port }
        } catch {}
    }
    ([ordered]@{ mode = 'PushToTalk'; host = $destHost; port = $destPort; hotkeys = @(163) } | ConvertTo-Json) |
        Set-Content -Path $cfg -Encoding UTF8
}
