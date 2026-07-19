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

# Always refresh the program files; preserve an existing user config (chosen mode).
Copy-Item (Join-Path $srcDir 'hermes_hotkey.ps1')   (Join-Path $destDir 'hermes_hotkey.ps1')   -Force
Copy-Item (Join-Path $srcDir 'hermes_launcher.vbs') (Join-Path $destDir 'hermes_launcher.vbs') -Force
$destCfg = Join-Path $destDir 'hermes.config.json'
if (-not (Test-Path $destCfg)) {
    Copy-Item (Join-Path $srcDir 'hermes.config.json') $destCfg -Force
}

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
Write-Host "Note: the ADB port-forward (tcp:9999) and the Android app must be running" -ForegroundColor DarkYellow
Write-Host "for the tray icon to turn active; the daemon retries the connection automatically." -ForegroundColor DarkYellow
