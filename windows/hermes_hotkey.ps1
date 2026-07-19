# Project Hermes - Native Windows PowerShell Global Hotkey Daemon
# Listens globally for F12 (VK 123) and Dell Search Key (VK 170) using Win32 GetAsyncKeyState.
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
Write-Host "🎙️ Project Hermes Native Windows Companion (PowerShell Daemon)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Press & Hold [F12] (or Dell Search Key) to Dictate." -ForegroundColor Yellow
Write-Host "Release [F12] when finished speaking." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to exit.`n" -ForegroundColor Gray

$tcpClient = $null
$stream = $null

function Connect-Transport {
    try {
        $global:tcpClient = New-Object System.Net.Sockets.TcpClient($HOST_IP, $PORT)
        $global:stream = $global:tcpClient.GetStream()
        Write-Host "✅ Connected to Android transport server at $HOST_IP`:$PORT" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "⚠️ Connecting to Android transport server at $HOST_IP`:$PORT failed. Retrying..." -ForegroundColor Red
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
    # Check if F12 (123) or Search Key (170) or Calculator Key (183) is pressed (MSB bit set)
    $stateF12 = [Win32Keyboard]::GetAsyncKeyState($VK_F12) -band 0x8000
    $stateSearch = [Win32Keyboard]::GetAsyncKeyState($VK_SEARCH) -band 0x8000
    $stateCalc = [Win32Keyboard]::GetAsyncKeyState($VK_CALCULATOR) -band 0x8000

    $isKeyPressed = ($stateF12 -ne 0) -or ($stateSearch -ne 0) -or ($stateCalc -ne 0)

    if ($isKeyPressed -and -not $isListening) {
        $isListening = $true
        Write-Host "`n🔴 [HOTKEY DOWN] F12 / Search Key Pressed! Speech Recognition STARTED." -ForegroundColor Red
        Send-HermesCommand "start_listening"
    } elseif (-not $isKeyPressed -and $isListening) {
        $isListening = $false
        Write-Host "`n⏹️ [HOTKEY UP] F12 / Search Key Released! Speech Recognition STOPPED." -ForegroundColor Yellow
        Send-HermesCommand "stop_listening"
    }

    # Process incoming responses from Android server non-blocking
    if ($global:stream.DataAvailable) {
        $line = $reader.ReadLine()
        if ($line) {
            if ($line -match '"type"\s*:\s*"partial"') {
                if ($line -match '"text"\s*:\s*"([^"]+)"') {
                    $text = $Matches[1]
                    Write-Host "  ... Partial: `"$text`"" -ForegroundColor DarkGray
                }
            } elseif ($line -match '"type"\s*:\s*"final"') {
                if ($line -match '"text"\s*:\s*"([^"]+)"') {
                    $text = $Matches[1]
                    Write-Host "`n✨ [FINAL SPEECH RESULT]: `"$text`"`n" -ForegroundColor Green
                    # Inject text into currently focused active Windows window
                    [System.Windows.Forms.SendKeys]::SendWait($text)
                }
            } elseif ($line -match '"type"\s*:\s*"heartbeat"') {
                Write-Host "💓 [HEARTBEAT]: Android Server Ready" -ForegroundColor DarkCyan
            }
        }
    }

    Start-Sleep -Milliseconds 50
}
