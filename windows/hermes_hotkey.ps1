# Project Hermes - Native Windows PowerShell Global Hotkey Daemon
# Listens globally for F12 (VK 123), Dell Search Key (VK 170), and Calculator Key (VK 183).
# Sends protocol commands over TCP port 9999 to Android and injects text into active window.

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32Keyboard {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
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
Write-Host "Press & Hold [F12] (or Dell Search Key / Calculator Key) to Dictate." -ForegroundColor Yellow
Write-Host "Release key when finished speaking." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to exit.`n" -ForegroundColor Gray

$tcpClient = $null
$stream = $null

function Connect-Transport {
    try {
        $global:tcpClient = New-Object System.Net.Sockets.TcpClient($HOST_IP, $PORT)
        $global:stream = $global:tcpClient.GetStream()
        Write-Host "Connected to Android transport server at $HOST_IP`:$PORT" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Connecting to Android transport server at $HOST_IP`:$PORT failed. Retrying..." -ForegroundColor Red
        return $false
    }
}

while (-not (Connect-Transport)) {
    Start-Sleep -Seconds 2
}

$isListening = $false
$reader = New-Object System.IO.StreamReader($global:stream)
$writer = New-Object System.IO.StreamWriter($global:stream)
$writer.AutoFlush = $true

function Send-HermesCommand($cmdName) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $json = "{`"version`":`"1.0`",`"type`":`"command`",`"command`":`"$cmdName`",`"timestamp`":$ts}"
    $writer.WriteLine($json)
}

# Main Event Loop
while ($true) {
    $stateF12 = [Win32Keyboard]::GetAsyncKeyState($VK_F12) -band 0x8000
    $stateSearch = [Win32Keyboard]::GetAsyncKeyState($VK_SEARCH) -band 0x8000
    $stateCalc = [Win32Keyboard]::GetAsyncKeyState($VK_CALCULATOR) -band 0x8000

    $isKeyPressed = ($stateF12 -ne 0) -or ($stateSearch -ne 0) -or ($stateCalc -ne 0)

    if ($isKeyPressed -and -not $isListening) {
        $isListening = $true
        Write-Host "`n[HOTKEY DOWN] F12 / Search Key Pressed! Speech Recognition STARTED." -ForegroundColor Red
        Send-HermesCommand "start_listening"
    } elseif (-not $isKeyPressed -and $isListening) {
        $isListening = $false
        Write-Host "`n[HOTKEY UP] F12 / Search Key Released! Speech Recognition STOPPED." -ForegroundColor Yellow
        Send-HermesCommand "stop_listening"
    }

    if ($global:stream.DataAvailable) {
        $line = $reader.ReadLine()
        if ($line) {
            if ($line.Contains('"type":"partial"') -or $line.Contains('"type": "partial"')) {
                Write-Host "  ... Partial result received: $line" -ForegroundColor DarkGray
            } elseif ($line.Contains('"type":"final"') -or $line.Contains('"type": "final"')) {
                Write-Host "`n[FINAL SPEECH RESULT]: $line`n" -ForegroundColor Green
                # Parse text using IndexOf
                $idx = $line.IndexOf('"text":')
                if ($idx -ge 0) {
                    $sub = $line.Substring($idx + 8)
                    $endIdx = $sub.IndexOf('",')
                    if ($endIdx -lt 0) { $endIdx = $sub.IndexOf('"}') }
                    if ($endIdx -gt 0) {
                        $cleanText = $sub.Substring(0, $endIdx)
                        Write-Host "Injecting Text: $cleanText" -ForegroundColor Cyan
                        [System.Windows.Forms.SendKeys]::SendWait($cleanText)
                    }
                }
            } elseif ($line.Contains('"type":"heartbeat"') -or $line.Contains('"type": "heartbeat"')) {
                Write-Host "[HEARTBEAT]: Android Server Ready" -ForegroundColor DarkCyan
            }
        }
    }

    Start-Sleep -Milliseconds 50
}
