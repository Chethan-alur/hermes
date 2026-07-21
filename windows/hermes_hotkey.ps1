# Project Hermes - Native Windows Companion (PowerShell Daemon)
# ------------------------------------------------------------------------------
# Global hotkey dictation bridge. Listens for a configurable global hotkey (default:
# Right Ctrl, VK 163 -- a modifier, so holding it never triggers app actions),
# streams speech commands to the Android companion over TCP, and pastes the returned
# transcript into the active window. Runs from the system tray and supports two modes:
#
#   Toggle       - tap the hotkey to start, tap again to stop.
#   PushToTalk   - hold the hotkey to talk, release to stop and paste.
#
# Configuration is read from hermes.config.json next to this script; the tray icon
# menu can switch modes at runtime and persists the choice.
# ------------------------------------------------------------------------------

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

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

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
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Paths ---------------------------------------------------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$global:ConfigPath = Join-Path $ScriptDir 'hermes.config.json'
$global:LogPath    = Join-Path $ScriptDir 'hermes.log'

# --- Logging -------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray)
    $stamp = (Get-Date).ToString('HH:mm:ss')
    try { Write-Host $Message -ForegroundColor $Color } catch {}
    try { Add-Content -Path $global:LogPath -Value "$stamp  $Message" -ErrorAction SilentlyContinue } catch {}
}

# --- Configuration -------------------------------------------------------------
function Load-Config {
    $cfg = [ordered]@{ mode = 'PushToTalk'; host = '127.0.0.1'; port = 9999; hotkeys = @(163) }  # 163 = Right Ctrl
    if (Test-Path $global:ConfigPath) {
        try {
            $j = Get-Content $global:ConfigPath -Raw | ConvertFrom-Json
            if ($j.mode)    { $cfg.mode = [string]$j.mode }
            if ($j.host)    { $cfg.host = [string]$j.host }
            if ($j.port)    { $cfg.port = [int]$j.port }
            if ($j.hotkeys) { $cfg.hotkeys = @($j.hotkeys | ForEach-Object { [int]$_ }) }
        } catch { Write-Log "Config parse failed; using defaults. $($_.Exception.Message)" 'DarkYellow' }
    }
    if ($cfg.mode -ne 'Toggle' -and $cfg.mode -ne 'PushToTalk') { $cfg.mode = 'PushToTalk' }
    return $cfg
}

function Save-Config {
    $obj = [ordered]@{ mode = $script:Mode; host = $HOST_IP; port = $PORT; hotkeys = $VK_LIST }
    try { ($obj | ConvertTo-Json) | Set-Content -Path $global:ConfigPath -Encoding UTF8 } catch {}
}

$cfg      = Load-Config
$HOST_IP  = $cfg.host
$PORT     = [int]$cfg.port
$VK_LIST  = @($cfg.hotkeys)
$script:Mode        = $cfg.mode
$script:isListening = $false
$script:ShouldExit  = $false
$script:targetHwnd  = [IntPtr]::Zero
$script:consoleHwnd = [Win32Input]::GetConsoleWindow()

# --- Tray icons (drawn in code so no external asset is needed) ------------------
function New-CircleIcon([System.Drawing.Color]$fill) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $fill
    $g.FillEllipse($brush, 2, 2, 11, 11)
    $brush.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}
$global:IconIdle = New-CircleIcon ([System.Drawing.Color]::FromArgb(38, 166, 154))  # teal
$global:IconRec  = New-CircleIcon ([System.Drawing.Color]::FromArgb(229, 57, 53))   # red

# --- System tray ---------------------------------------------------------------
$script:menu       = New-Object System.Windows.Forms.ContextMenuStrip
$script:itemStatus = New-Object System.Windows.Forms.ToolStripMenuItem 'Status: Ready'
$script:itemStatus.Enabled = $false
$script:itemToggle = New-Object System.Windows.Forms.ToolStripMenuItem 'Mode: Toggle (tap to start/stop)'
$script:itemPTT    = New-Object System.Windows.Forms.ToolStripMenuItem 'Mode: Push-to-Talk (hold to talk)'
$script:itemExit   = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit Hermes'

$script:itemToggle.Add_Click({ Set-Mode 'Toggle' })
$script:itemPTT.Add_Click({ Set-Mode 'PushToTalk' })
$script:itemExit.Add_Click({ $script:ShouldExit = $true })

$script:menu.Items.Add($script:itemStatus) | Out-Null
$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$script:menu.Items.Add($script:itemToggle) | Out-Null
$script:menu.Items.Add($script:itemPTT) | Out-Null
$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$script:menu.Items.Add($script:itemExit) | Out-Null

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = $global:IconIdle
$script:notify.Text = 'Project Hermes - Ready'
$script:notify.Visible = $true
$script:notify.ContextMenuStrip = $script:menu

function Update-ModeChecks {
    $script:itemToggle.Checked = ($script:Mode -eq 'Toggle')
    $script:itemPTT.Checked    = ($script:Mode -eq 'PushToTalk')
}

function Set-Mode($m) {
    $script:Mode = $m
    Update-ModeChecks
    Save-Config
    if (-not $script:isListening) { $script:notify.Text = "Project Hermes - Ready ($m)" }
    Write-Log "Mode switched to: $m" 'Cyan'
}

function Set-ListeningState($listening) {
    $script:isListening = $listening
    if ($listening) {
        $script:notify.Icon = $global:IconRec
        $script:notify.Text = 'Project Hermes - Listening...'
        $script:itemStatus.Text = 'Status: Listening...'
    } else {
        $script:notify.Icon = $global:IconIdle
        $script:notify.Text = "Project Hermes - Ready ($script:Mode)"
        $script:itemStatus.Text = 'Status: Ready'
    }
}
Update-ModeChecks

# --- Transport -----------------------------------------------------------------
$global:recvBuffer  = New-Object System.Text.StringBuilder
$readByteBuffer     = New-Object 'byte[]' 4096

# Reconnect/backoff state (see Ensure-Connected). Mirrors windows/transport/tcp_client.py:
# bounded connect timeout + capped exponential backoff, so an unreachable phone never freezes
# the tray.
$script:ConnectTimeoutMs    = 3000
$script:BackoffMinMs        = 1000
$script:BackoffMaxMs        = 30000
$script:BackoffMs           = $script:BackoffMinMs
$script:NextConnectAt       = 0
$script:AnnouncedConnecting = $false

function Close-Transport {
    try { if ($global:writer)    { $global:writer.Dispose() } }  catch {}
    try { if ($global:stream)    { $global:stream.Dispose() } }  catch {}
    try { if ($global:tcpClient) { $global:tcpClient.Close() } } catch {}
    $global:writer = $null; $global:stream = $null; $global:tcpClient = $null
}

function Try-Connect {
    # Non-blocking connect bounded by $script:ConnectTimeoutMs. Unlike the blocking
    # TcpClient(host, port) constructor -- which parks the WinForms message pump for the full
    # ~20s OS timeout on an unreachable host (the original tray "freeze") -- this drives
    # BeginConnect and pumps DoEvents while it waits, so the tray stays responsive.
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    try {
        $iar = $client.BeginConnect($HOST_IP, $PORT, $null, $null)
        $deadline = [Environment]::TickCount + $script:ConnectTimeoutMs
        while (-not $iar.AsyncWaitHandle.WaitOne(50)) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:ShouldExit)                     { $client.Close(); return $false }
            if ([Environment]::TickCount -ge $deadline) { $client.Close(); return $false }
        }
        $client.EndConnect($iar)   # throws if the connection attempt failed
    } catch {
        try { $client.Close() } catch {}
        return $false
    }
    if (-not $client.Connected) { try { $client.Close() } catch {}; return $false }

    $global:tcpClient = $client
    $global:stream    = $client.GetStream()
    # Only a StreamWriter for OUTBOUND commands. Inbound data is read raw off the socket
    # (see the drain loop): a StreamReader reads ahead into its own buffer and would strand
    # complete lines behind $stream.DataAvailable.
    $global:writer = New-Object System.IO.StreamWriter($global:stream)
    $global:writer.AutoFlush = $true
    Write-Log "Connected to Android transport server at ${HOST_IP}:${PORT}" 'Green'
    return $true
}

function Ensure-Connected {
    # Called once per main-loop iteration. Non-blocking: returns immediately while backing off,
    # and makes at most one bounded connect attempt per interval, so an unreachable phone never
    # freezes the tray. Backoff grows to $script:BackoffMaxMs and resets on success.
    if ($global:tcpClient -and $global:tcpClient.Connected) { return $true }
    if ([Environment]::TickCount -lt $script:NextConnectAt) { return $false }

    if (-not $script:AnnouncedConnecting) {
        Write-Log "Connecting to Android transport server at ${HOST_IP}:${PORT} (auto-retrying with backoff)..." 'DarkYellow'
        $script:AnnouncedConnecting = $true
    }
    if (-not $script:isListening) { $script:itemStatus.Text = 'Status: Connecting...' }

    if (Try-Connect) {
        $script:BackoffMs = $script:BackoffMinMs
        $script:AnnouncedConnecting = $false
        if (-not $script:isListening) { $script:itemStatus.Text = 'Status: Ready' }
        return $true
    }

    $script:NextConnectAt = [Environment]::TickCount + $script:BackoffMs
    $script:BackoffMs = [Math]::Min($script:BackoffMs * 2, $script:BackoffMaxMs)
    return $false
}

function Send-HermesCommand($cmdName) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $json = "{`"version`":`"1.0`",`"type`":`"command`",`"command`":`"$cmdName`",`"timestamp`":$ts}"
    try { if ($global:writer) { $global:writer.WriteLine($json) } } catch {}
}

# --- Window focus + paste ------------------------------------------------------
function Get-WindowTitle($hWnd) {
    if (-not $hWnd -or $hWnd -eq [IntPtr]::Zero) { return '<none>' }
    $sb = New-Object System.Text.StringBuilder 256
    [void][Win32Input]::GetWindowText($hWnd, $sb, $sb.Capacity)
    $t = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($t)) { return "<hwnd $($hWnd.ToInt64())>" }
    return $t
}

function Set-WindowsTextClipboard($textToCopy) {
    try { Set-Clipboard -Value $textToCopy }
    catch {
        try { $textToCopy | clip.exe }
        catch { [System.Windows.Forms.Clipboard]::SetText($textToCopy) }
    }
}

function Set-ForceForeground($hWnd) {
    # Defeat the Windows 11 foreground lock: attach our input queue to the current
    # foreground thread and the target thread so SetForegroundWindow is honoured.
    if (-not $hWnd -or $hWnd -eq [IntPtr]::Zero) { return $false }
    $SW_RESTORE = 9
    if ([Win32Input]::IsIconic($hWnd)) { [Win32Input]::ShowWindow($hWnd, $SW_RESTORE) | Out-Null }

    $foreWnd      = [Win32Input]::GetForegroundWindow()
    $foreThread   = [Win32Input]::GetWindowThreadProcessId($foreWnd, [IntPtr]::Zero)
    $targetThread = [Win32Input]::GetWindowThreadProcessId($hWnd, [IntPtr]::Zero)
    $curThread    = [Win32Input]::GetCurrentThreadId()

    $attachedFore = $false; $attachedTarget = $false
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
    # Focus the window captured when dictation started; otherwise paste into whatever
    # window currently has focus. Never force a specific app such as Notepad.
    $target = $script:targetHwnd
    if ($target -and $target -ne [IntPtr]::Zero) {
        $focused = Set-ForceForeground $target
        if (-not $focused) { Write-Log "Could not focus '$(Get-WindowTitle $target)'; pasting into foreground." 'DarkYellow' }
        Start-Sleep -Milliseconds 120
    }
    [Win32Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero) # Ctrl down
    [Win32Input]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero) # V down
    Start-Sleep -Milliseconds 40
    [Win32Input]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero) # V up
    [Win32Input]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) # Ctrl up
}

# --- Dictation control ---------------------------------------------------------
function Start-Dictation {
    if ($script:isListening) { return }
    $fg = [Win32Input]::GetForegroundWindow()
    if ($fg.ToInt64() -ne 0 -and $fg.ToInt64() -ne $script:consoleHwnd.ToInt64()) {
        $script:targetHwnd = $fg
        Write-Log "Target window: $(Get-WindowTitle $fg)" 'DarkCyan'
    } else {
        $script:targetHwnd = [IntPtr]::Zero
    }
    Set-ListeningState $true
    Send-HermesCommand 'start_listening'
    Write-Log 'Listening started.' 'Red'
}

function Stop-Dictation {
    if (-not $script:isListening) { return }
    Set-ListeningState $false
    Send-HermesCommand 'stop_listening'
    Write-Log 'Listening stopped; awaiting transcript.' 'Yellow'
}

function Process-HermesLine($line) {
    if (-not $line -or $line.Trim().Length -eq 0) { return }
    try {
        $msg = $line | ConvertFrom-Json
        switch ($msg.type) {
            'partial' { Write-Log "  partial: $($msg.text)" 'DarkGray' }
            'final' {
                $ftext = $msg.text
                Write-Log "Transcript: $ftext" 'Green'
                if ($ftext -and $ftext.Trim().Length -gt 0) {
                    # Append a trailing space so consecutive dictations stay separated.
                    Set-WindowsTextClipboard ($ftext.TrimEnd() + ' ')
                    Start-Sleep -Milliseconds 100
                    Send-Win32Paste
                }
            }
            'error'     { Write-Log "Speech error: $($msg.message) (Code: $($msg.code))" 'Red' }
            'heartbeat' { }  # keep-alive; no action
        }
    } catch { }
}

# --- Startup -------------------------------------------------------------------
Write-Log '============================================================' 'Cyan'
Write-Log 'Project Hermes - Windows Companion (system tray)' 'Cyan'
Write-Log "Mode: $script:Mode   Hotkey VK: $($VK_LIST -join ', ') (default 163 = Right Ctrl)" 'Cyan'
Write-Log 'Right-click the tray icon to switch mode or exit.' 'Gray'
Write-Log '============================================================' 'Cyan'

# The connection is established (and re-established) non-blocking inside the main loop via
# Ensure-Connected, so the tray appears and stays responsive even when the phone is not yet
# reachable -- no blocking connect loop at startup.
$wasKeyPressed = $false

# --- Main event loop -----------------------------------------------------------
while (-not $script:ShouldExit) {
    [System.Windows.Forms.Application]::DoEvents()   # service tray menu events

    $connected = Ensure-Connected                    # non-blocking connect/reconnect with backoff

    # Hotkey edge detection
    $isKeyPressed = $false
    foreach ($vk in $VK_LIST) {
        if (([Win32Input]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0) { $isKeyPressed = $true; break }
    }

    if ($script:Mode -eq 'PushToTalk') {
        if ($isKeyPressed -and -not $wasKeyPressed) { Start-Dictation }
        elseif (-not $isKeyPressed -and $wasKeyPressed) { Stop-Dictation }
    } else { # Toggle
        if ($isKeyPressed -and -not $wasKeyPressed) {
            if (-not $script:isListening) { Start-Dictation } else { Stop-Dictation }
        }
    }
    $wasKeyPressed = $isKeyPressed

    # Non-blocking socket drain with disconnect detection. Reconnect is handled by
    # Ensure-Connected on later iterations (with backoff) -- never by a blocking loop.
    if ($connected) {
        try {
            $sock = $global:tcpClient.Client
            if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $global:tcpClient.Available -eq 0) {
                throw 'Remote server closed the connection.'
            }
            while ($global:tcpClient.Available -gt 0) {
                $count = $global:stream.Read($readByteBuffer, 0, $readByteBuffer.Length)
                if ($count -le 0) { throw 'Remote server closed the connection.' }
                [void]$global:recvBuffer.Append([System.Text.Encoding]::UTF8.GetString($readByteBuffer, 0, $count))
            }
            $buffered = $global:recvBuffer.ToString()
            $nl = $buffered.IndexOf("`n")
            while ($nl -ge 0) {
                $lineText = $buffered.Substring(0, $nl).TrimEnd("`r")
                $buffered = $buffered.Substring($nl + 1)
                Process-HermesLine $lineText
                $nl = $buffered.IndexOf("`n")
            }
            [void]$global:recvBuffer.Clear()
            [void]$global:recvBuffer.Append($buffered)
        } catch {
            Write-Log "Disconnected: $($_.Exception.Message) Will reconnect." 'Red'
            Close-Transport
            [void]$global:recvBuffer.Clear()
            Set-ListeningState $false
            # Reconnect promptly with a fresh backoff; Ensure-Connected does it non-blocking.
            $script:BackoffMs = $script:BackoffMinMs
            $script:NextConnectAt = 0
            $script:AnnouncedConnecting = $false
        }
    }

    Start-Sleep -Milliseconds 40
}

# --- Cleanup -------------------------------------------------------------------
Write-Log 'Shutting down Hermes companion.' 'Gray'
try { $script:notify.Visible = $false; $script:notify.Dispose() } catch {}
try { if ($global:writer) { $global:writer.Dispose() } } catch {}
try { if ($global:stream) { $global:stream.Dispose() } } catch {}
try { if ($global:tcpClient) { $global:tcpClient.Close() } } catch {}
