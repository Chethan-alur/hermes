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

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    // lpdwProcessId is allowed to be NULL, so we accept IntPtr and pass IntPtr.Zero.
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
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
Write-Host "TOGGLE MODE: Click into your target window (Notepad, Word)," -ForegroundColor Yellow
Write-Host "then press [F12] (or Search/Calc key) once to START." -ForegroundColor Yellow
Write-Host "Press [F12] once again to STOP and paste into that window." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to exit." -ForegroundColor Gray
Write-Host ""

$tcpClient = $null
$stream = $null

function Connect-Transport {
    try {
        $global:tcpClient = New-Object System.Net.Sockets.TcpClient($HOST_IP, $PORT)
        $global:stream = $global:tcpClient.GetStream()
        # NOTE: We only use a StreamWriter for OUTBOUND commands. Inbound data is read
        # raw off the socket (see the drain loop below). A StreamReader must NOT be used
        # here: StreamReader.ReadLine() reads ahead into its own managed buffer, so gating
        # reads on $stream.DataAvailable strands complete lines (a 'final' transcript) that
        # then never fire the paste. $reader.Peek() would detect them but blocks on a
        # NetworkStream, which is why it was removed previously.
        $global:writer = New-Object System.IO.StreamWriter($global:stream)
        $global:writer.AutoFlush = $true
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

# Raw receive buffer: we drain bytes via $tcpClient.Available and split lines ourselves.
$global:recvBuffer = New-Object System.Text.StringBuilder
$readByteBuffer = New-Object 'byte[]' 4096

# Remember our own console/terminal window so we never treat it as the paste target.
$global:consoleHwnd = [Win32Input]::GetForegroundWindow()
$global:targetHwnd = [IntPtr]::Zero

function Send-HermesCommand($cmdName) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $json = "{`"version`":`"1.0`",`"type`":`"command`",`"command`":`"$cmdName`",`"timestamp`":$ts}"
    if ($global:writer) {
        $global:writer.WriteLine($json)
    }
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

function Get-WindowTitle($hWnd) {
    if (-not $hWnd -or $hWnd -eq [IntPtr]::Zero) { return "<none>" }
    $sb = New-Object System.Text.StringBuilder 256
    [void][Win32Input]::GetWindowText($hWnd, $sb, $sb.Capacity)
    $t = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($t)) { return "<hwnd $($hWnd.ToInt64())>" }
    return $t
}

function Set-ForceForeground($hWnd) {
    # Reliably bring a window to the foreground despite the Windows 11 foreground lock.
    # A background console process cannot normally SetForegroundWindow() another app's
    # window; temporarily attaching our input queue to the current foreground thread and
    # the target thread lifts that restriction, after which SetForegroundWindow succeeds.
    if (-not $hWnd -or $hWnd -eq [IntPtr]::Zero) { return $false }

    $SW_RESTORE = 9
    if ([Win32Input]::IsIconic($hWnd)) {
        [Win32Input]::ShowWindow($hWnd, $SW_RESTORE) | Out-Null
    }

    $foreWnd      = [Win32Input]::GetForegroundWindow()
    $foreThread   = [Win32Input]::GetWindowThreadProcessId($foreWnd, [IntPtr]::Zero)
    $targetThread = [Win32Input]::GetWindowThreadProcessId($hWnd, [IntPtr]::Zero)
    $curThread    = [Win32Input]::GetCurrentThreadId()

    $attachedFore   = $false
    $attachedTarget = $false
    if ($foreThread -ne 0 -and $foreThread -ne $curThread) {
        $attachedFore = [Win32Input]::AttachThreadInput($curThread, $foreThread, $true)
    }
    if ($targetThread -ne 0 -and $targetThread -ne $curThread -and $targetThread -ne $foreThread) {
        $attachedTarget = [Win32Input]::AttachThreadInput($curThread, $targetThread, $true)
    }

    [Win32Input]::BringWindowToTop($hWnd) | Out-Null
    [Win32Input]::ShowWindow($hWnd, $SW_RESTORE) | Out-Null
    $ok = [Win32Input]::SetForegroundWindow($hWnd)

    if ($attachedTarget) { [Win32Input]::AttachThreadInput($curThread, $targetThread, $false) | Out-Null }
    if ($attachedFore)   { [Win32Input]::AttachThreadInput($curThread, $foreThread, $false) | Out-Null }
    return $ok
}

function Send-Win32Paste {
    # If we captured the window that was focused when dictation started, bring it forward
    # and paste there. Otherwise paste into whatever window currently has focus. We never
    # force a specific app such as Notepad -- that would hijack text away from the window
    # the user actually intended.
    $target = $global:targetHwnd

    if ($target -and $target -ne [IntPtr]::Zero) {
        $title = Get-WindowTitle $target
        $focused = Set-ForceForeground $target
        if ($focused) {
            Write-Host "  [PASTE] Into captured window: $title" -ForegroundColor DarkCyan
        } else {
            Write-Host "  [PASTE] Could not focus '$title'; pasting into current foreground window instead." -ForegroundColor DarkYellow
        }
        Start-Sleep -Milliseconds 120
    } else {
        $fgNow = [Win32Input]::GetForegroundWindow()
        Write-Host "  [PASTE] Into current foreground window: $(Get-WindowTitle $fgNow)" -ForegroundColor DarkCyan
    }

    [Win32Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero) # Ctrl DOWN
    [Win32Input]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero) # V DOWN
    Start-Sleep -Milliseconds 40
    [Win32Input]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero) # V UP
    [Win32Input]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) # Ctrl UP
}

function Process-HermesLine($line) {
    if (-not $line -or $line.Trim().Length -eq 0) { return }
    try {
        $msg = $line | ConvertFrom-Json
        if ($msg.type -eq "partial") {
            $ptext = $msg.text
            Write-Host "  ... Partial: $ptext" -ForegroundColor DarkGray
        } elseif ($msg.type -eq "final") {
            $ftext = $msg.text
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host "[FINAL TRANSCRIPT]: $ftext" -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host ""
            if ($ftext -and $ftext.Trim().Length -gt 0) {
                Write-Host "[COPYING TO CLIPBOARD & PASTING VIA Ctrl+V]: $ftext" -ForegroundColor Cyan
                Set-WindowsTextClipboard $ftext
                Start-Sleep -Milliseconds 100
                Send-Win32Paste
            }
        } elseif ($msg.type -eq "error") {
            $errText = $msg.message
            $errCode = $msg.code
            Write-Host ""
            Write-Host "[SPEECH ERROR]: $errText (Code: $errCode)" -ForegroundColor Red
            Write-Host ""
        } elseif ($msg.type -eq "heartbeat") {
            Write-Host "[HEARTBEAT]: Android Server Ready" -ForegroundColor DarkCyan
        }
    } catch {
        Write-Host "  ... TCP Payload: $line" -ForegroundColor Gray
    }
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
            # Capture the window the user is currently working in so we can paste back
            # into it later. Ignore our own console so we do not paste into this terminal.
            # Compare handle values as Int64 -- IntPtr -eq/-ne is unreliable in PowerShell.
            $fg = [Win32Input]::GetForegroundWindow()
            Write-Host ""
            if ($fg.ToInt64() -ne 0 -and $fg.ToInt64() -ne $global:consoleHwnd.ToInt64()) {
                $global:targetHwnd = $fg
                Write-Host "[TARGET] Captured active window: $(Get-WindowTitle $fg)" -ForegroundColor DarkCyan
            } else {
                $global:targetHwnd = [IntPtr]::Zero
                Write-Host "[TARGET] Foreground is this daemon console; will paste into whatever window is focused when the transcript arrives." -ForegroundColor DarkYellow
            }
            Write-Host "[SPEECH STARTED] Speak into phone now... Press [F12] when done." -ForegroundColor Red
            Send-HermesCommand "start_listening"
        } else {
            $isListening = $false
            Write-Host ""
            Write-Host "[SPEECH STOPPED] Processing transcript on Pixel 8 NPU..." -ForegroundColor Yellow
            Send-HermesCommand "stop_listening"
        }
    }
    $wasKeyPressed = $isKeyPressed

    # Non-blocking socket drain: pull every available byte off the socket, then process
    # each complete newline-terminated line. Any trailing partial line is kept for the
    # next tick. This avoids the StreamReader/DataAvailable pitfall where read-ahead
    # buffering strands a complete 'final' line so the paste never fires. Socket errors
    # (the Android server routinely closes/reopens the connection) trigger a reconnect.
    try {
        # Poll detects a graceful remote close: readable with zero bytes available.
        $sock = $global:tcpClient.Client
        if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $global:tcpClient.Available -eq 0) {
            throw "Remote server closed the connection."
        }

        while ($global:tcpClient.Available -gt 0) {
            $count = $global:stream.Read($readByteBuffer, 0, $readByteBuffer.Length)
            if ($count -le 0) { throw "Remote server closed the connection." }
            [void]$global:recvBuffer.Append([System.Text.Encoding]::UTF8.GetString($readByteBuffer, 0, $count))
        }

        $buffered = $global:recvBuffer.ToString()
        $nl = $buffered.IndexOf("`n")
        while ($nl -ge 0) {
            $line = $buffered.Substring(0, $nl).TrimEnd("`r")
            $buffered = $buffered.Substring($nl + 1)
            Process-HermesLine $line
            $nl = $buffered.IndexOf("`n")
        }
        [void]$global:recvBuffer.Clear()
        [void]$global:recvBuffer.Append($buffered)
    } catch {
        Write-Host ""
        Write-Host "[DISCONNECTED] $($_.Exception.Message) Reconnecting..." -ForegroundColor Red
        try { if ($global:writer) { $global:writer.Dispose() } } catch {}
        try { if ($global:stream) { $global:stream.Dispose() } } catch {}
        try { if ($global:tcpClient) { $global:tcpClient.Close() } } catch {}
        $global:writer = $null
        [void]$global:recvBuffer.Clear()
        $isListening = $false
        while (-not (Connect-Transport)) { Start-Sleep -Seconds 2 }
    }

    Start-Sleep -Milliseconds 50
}
