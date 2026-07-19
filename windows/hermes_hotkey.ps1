# Project Hermes - Native Windows PowerShell Global Hotkey Daemon
# Listens globally for F12 (VK 123), Dell Search Key (VK 170), and Calculator Key (VK 183).
# Toggle Mode with Key Edge Detection: Press key ONCE to START -> Speak -> Press key ONCE again to STOP & Paste.

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32Input {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

Add-Type -AssemblyName System.Windows.Forms

$HOST_IP = "127.0.0.1"
$PORT = 9999
$VK_F12 = 123
$VK_SEARCH = 170
$VK_CALCULATOR = 183

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Project Hermes Native Windows Companion (PowerShell Daemon)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "TOGGLE MODE: Press [F12] (or Search/Calc key) once to START." -ForegroundColor Yellow
Write-Host "Press [F12] key once again to STOP and paste into active window." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to exit." -ForegroundColor Gray
Write-Host ""

$tcpClient = $null
$stream = $null

function Connect-Transport {
    try {
        $global:tcpClient = New-Object System.Net.Sockets.TcpClient($HOST_IP, $PORT)
        $global:stream = $global:tcpClient.GetStream()
        Write-Host "[CONNECTED] Connected to Android transport server at $HOST_IP`:$PORT" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[RETRY] Connecting to Android transport server at $HOST_IP`:$PORT failed. Retrying..." -ForegroundColor Red
        return $false
    }
}

while (-not (Connect-Transport)) {
    Start-Sleep -Seconds 2
}

$isListening = $false
$wasKeyPressed = $false
$reader = New-Object System.IO.StreamReader($global:stream)
$writer = New-Object System.IO.StreamWriter($global:stream)
$writer.AutoFlush = $true

function Send-HermesCommand($cmdName) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $json = "{`"version`":`"1.0`",`"type`":`"command`",`"command`":`"$cmdName`",`"timestamp`":$ts}"
    $writer.WriteLine($json)
}

function Set-WindowsTextClipboard($textToCopy) {
    try {
        Set-Clipboard -Value $textToCopy
    } catch {
        try {
            $textToCopy | clip.exe
        } catch {
            [System.Windows.Forms.Clipboard]::SetText($textToCopy)
        }
    }
}

function Send-Win32Paste {
    [Win32Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [Win32Input]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [Win32Input]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
    [Win32Input]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}

# Main Event Loop
while ($true) {
    $stateF12 = [Win32Input]::GetAsyncKeyState($VK_F12) -band 0x8000
    $stateSearch = [Win32Input]::GetAsyncKeyState($VK_SEARCH) -band 0x8000
    $stateCalc = [Win32Input]::GetAsyncKeyState($VK_CALCULATOR) -band 0x8000

    $isKeyPressed = ($stateF12 -ne 0) -or ($stateSearch -ne 0) -or ($stateCalc -ne 0)

    if ($isKeyPressed -and -not $wasKeyPressed) {
        if (-not $isListening) {
            $isListening = $true
            Write-Host ""
            Write-Host "[KEY PRESS] F12 / Search Key Pressed -> SPEECH RECOGNITION STARTED. Speak into phone!" -ForegroundColor Red
            Send-HermesCommand "start_listening"
        } else {
            $isListening = $false
            Write-Host ""
            Write-Host "[KEY PRESS] F12 / Search Key Pressed -> SPEECH RECOGNITION STOPPED. Processing text..." -ForegroundColor Yellow
            Send-HermesCommand "stop_listening"
        }
    }
    $wasKeyPressed = $isKeyPressed

    while ($global:stream.DataAvailable -or ($reader.Peek() -ge 0)) {
        $line = $reader.ReadLine()
        if ($line -and $line.Trim().Length -gt 0) {
            try {
                $msg = $line | ConvertFrom-Json
                if ($msg.type -eq "partial") {
                    $ptext = $msg.text
                    Write-Host "  ... Partial: $ptext" -ForegroundColor DarkGray
                } elseif ($msg.type -eq "final") {
                    $ftext = $msg.text
                    Write-Host ""
                    Write-Host "[FINAL SPEECH RESULT]: $ftext" -ForegroundColor Green
                    Write-Host ""
                    if ($ftext -and $ftext.Trim().Length -gt 0) {
                        Write-Host "[PASTING TEXT VIA Ctrl+V]: $ftext" -ForegroundColor Cyan
                        Set-WindowsTextClipboard $ftext
                        Start-Sleep -Milliseconds 100
                        Send-Win32Paste
                    }
                } elseif ($msg.type -eq "heartbeat") {
                    Write-Host "[HEARTBEAT]: Android Server Ready" -ForegroundColor DarkCyan
                }
            } catch {
                Write-Host "  ... TCP Payload: $line" -ForegroundColor Gray
            }
        }
    }

    Start-Sleep -Milliseconds 50
}
