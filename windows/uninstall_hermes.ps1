# Project Hermes - Windows uninstaller
# ------------------------------------------------------------------------------
# Stops the tray daemon, removes the auto-start and Start Menu shortcuts, and deletes
# the installed program files from %LOCALAPPDATA%\ProjectHermes.
#
# Run from a Windows PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File windows\uninstall_hermes.ps1
# ------------------------------------------------------------------------------
$ErrorActionPreference = 'SilentlyContinue'

$destDir  = Join-Path $env:LOCALAPPDATA 'ProjectHermes'
$startup  = [Environment]::GetFolderPath('Startup')
$programs = [Environment]::GetFolderPath('Programs')

Write-Host "Uninstalling Project Hermes ..." -ForegroundColor Cyan

# Stop the running daemon(s).
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*hermes_hotkey.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# Remove shortcuts.
Remove-Item (Join-Path $startup  'Project Hermes.lnk') -Force
Remove-Item (Join-Path $programs 'Project Hermes.lnk') -Force

# Remove installed program files (keeps nothing behind).
if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }

Write-Host "Project Hermes uninstalled: daemon stopped, shortcuts and program files removed." -ForegroundColor Yellow
