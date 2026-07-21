# Project Hermes - build the self-extracting Setup.exe with IExpress (built into Windows).
# ---------------------------------------------------------------------------------------
# Wraps install_hermes.ps1 (+ its payload files) into windows\dist\ProjectHermes-Setup.exe
# using IExpress (iexpress.exe), which ships with Windows - no Inno Setup required.
#
# IExpress bakes absolute paths into its .SED and cannot read source files from a UNC path
# (e.g. a \\wsl.localhost\... checkout). So this script stages the payload into a LOCAL temp
# folder, substitutes the __STAGEDIR__ placeholder in hermes.sed with that folder, builds
# there, and copies the resulting .exe into windows\dist.
#
# Run from a native Windows shell:
#   powershell -ExecutionPolicy Bypass -File windows\installer\build_sfx.ps1
# or:  task windows:installer:sfx
$ErrorActionPreference = 'Stop'

$installerDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$winDir  = (Resolve-Path (Join-Path $installerDir '..')).ProviderPath
$distDir = Join-Path $winDir 'dist'
$iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
if (-not (Test-Path $iexpress)) { throw "IExpress not found at $iexpress" }

$payload = 'install_hermes.ps1', 'hermes_hotkey.ps1', 'hermes_launcher.vbs', 'hermes.config.json'

# Local (never-UNC) staging directory that IExpress can read from.
$stage = Join-Path $env:TEMP ('hermes-sfx-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    foreach ($f in $payload) { Copy-Item (Join-Path $winDir $f) (Join-Path $stage $f) -Force }

    # Fill the placeholder with the local stage path and normalise to CRLF/ASCII (IExpress is a
    # legacy INI-based tool and expects Windows line endings).
    $sed = (Get-Content (Join-Path $installerDir 'hermes.sed') -Raw).Replace('__STAGEDIR__', $stage.TrimEnd('\'))
    $sed = ($sed -replace "`r`n", "`n") -replace "`n", "`r`n"
    $sedPath = Join-Path $stage 'hermes.sed'
    [System.IO.File]::WriteAllText($sedPath, $sed, [System.Text.Encoding]::ASCII)

    Write-Host "Building ProjectHermes-Setup.exe via IExpress..." -ForegroundColor Cyan
    # iexpress.exe is a GUI-subsystem app: the call operator (&) would not wait for it and would
    # leave $LASTEXITCODE unset, so use Start-Process -Wait -PassThru to block and capture the code.
    $proc = Start-Process -FilePath $iexpress -ArgumentList '/N', '/Q', $sedPath -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "IExpress failed with exit code $($proc.ExitCode)" }

    $builtExe = Join-Path $stage 'ProjectHermes-Setup.exe'
    if (-not (Test-Path $builtExe)) { throw "IExpress did not produce $builtExe" }

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item $builtExe (Join-Path $distDir 'ProjectHermes-Setup.exe') -Force
    Write-Host "Built: $(Join-Path $distDir 'ProjectHermes-Setup.exe')" -ForegroundColor Green
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
