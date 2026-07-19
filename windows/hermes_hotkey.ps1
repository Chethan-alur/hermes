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
$reader = New-Object System.IO.StreamReader($global:stream)
$writer = New-Object System.IO.StreamWriter($global:stream)
$writer.AutoFlush = $true
$wsh = New-Object -ComObject WScript.Shell

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
        if ($line -and $line.Trim().Length -gt 0) {
            try {
                $msg = $line | ConvertFrom-Json
                if ($msg.type -eq "partial") {
                    Write-Host "  ... Partial: `"$($msg.text)`"" -ForegroundColor DarkGray
                } elseif ($msg.type -eq "final") {
                    Write-Host "`n[FINAL SPEECH RESULT]: `"$($msg.text)`"`n" -ForegroundColor Green
                    if ($msg.text -and $msg.text.Trim().Length -gt 0) {
                        Write-Host "[INJECTING TEXT INTO ACTIVE WINDOW]: '$($msg.text)'" -ForegroundColor Cyan
                        try {
                            $wsh.SendKeys($msg.text)
                        } catch {
                            [System.Windows.Forms.SendKeys]::SendWait($msg.text)
                        }
                    }
                } elseif ($msg.type -eq "heartbeat") {
                    Write-Host "[HEARTBEAT]: Android Server Ready" -ForegroundColor DarkCyan
                }
            } catch {
                Write-Host "  ... Raw TCP payload: $line" -ForegroundColor Gray
            }
        }
    }

    Start-Sleep -Milliseconds 50
}
