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
#
# Dev preview:  .\hermes_hotkey.ps1 -Preview   runs a scripted dictation (no phone / no TCP) that
# drives the on-screen overlay (REQ-FUNC-014) through Listening -> partial growth -> final -> fade,
# so its placement and focus-safety can be verified on the Windows host without the phone. It calls
# the same overlay functions the live path uses, so it also acts as a self-test.
# ------------------------------------------------------------------------------

param([switch]$Preview)

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
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox for editing transport IPs at runtime
[System.Windows.Forms.Application]::EnableVisualStyles()

# Dictation overlay window (REQ-FUNC-014). A borderless HUD that must NEVER become the foreground
# window: doing so would steal focus from the caret and break the paste-into-target-window flow.
# WS_EX_NOACTIVATE keeps it from ever activating; WS_EX_TRANSPARENT makes it click-through (mouse
# events fall to the editor beneath); WS_EX_TOOLWINDOW hides it from the taskbar / Alt-Tab;
# WS_EX_TOPMOST keeps it above other windows; WS_EX_LAYERED enables per-window Opacity. All drawing
# is done in a Paint handler with double-buffering (set in the constructor) to avoid flicker.
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @"
using System;
using System.Windows.Forms;
namespace Hermes {
    public class OverlayForm : Form {
        public OverlayForm() {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            UpdateStyles();
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
                cp.ExStyle |= 0x00080000; // WS_EX_LAYERED
                cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT (click-through)
                return cp;
            }
        }
    }
}
"@

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
    $cfg = [ordered]@{ mode = 'PushToTalk'; host = '127.0.0.1'; port = 9999; hotkeys = @(163); mic = 'auto'; overlay = $true; mdns = $true; hosts = @() }  # 163 = Right Ctrl
    if (Test-Path $global:ConfigPath) {
        try {
            $j = Get-Content $global:ConfigPath -Raw | ConvertFrom-Json
            if ($j.mode)    { $cfg.mode = [string]$j.mode }
            if ($j.host)    { $cfg.host = [string]$j.host }
            if ($j.port)    { $cfg.port = [int]$j.port }
            if ($j.hotkeys) { $cfg.hotkeys = @($j.hotkeys | ForEach-Object { [int]$_ }) }
            if ($j.mic)     { $cfg.mic = [string]$j.mic }
            # $null check (not truthiness) so an explicit overlay=false is honoured, not treated as "absent".
            if ($null -ne $j.overlay) { $cfg.overlay = [bool]$j.overlay }
            if ($null -ne $j.mdns)    { $cfg.mdns = [bool]$j.mdns }
            # Candidate server IPs to try (after mDNS). Plain list; migrate the old named-transport map.
            if ($j.hosts) {
                $cfg.hosts = @($j.hosts | ForEach-Object { [string]$_ } | Where-Object { $_ })
            } elseif ($j.transports) {
                $cfg.hosts = @($j.transports.PSObject.Properties | ForEach-Object { [string]$_.Value } | Where-Object { $_ })
            }
        } catch { Write-Log "Config parse failed; using defaults. $($_.Exception.Message)" 'DarkYellow' }
    }
    if ($cfg.mode -ne 'Toggle' -and $cfg.mode -ne 'PushToTalk') { $cfg.mode = 'PushToTalk' }
    if ($cfg.mic -notin @('auto','builtin','bluetooth')) { $cfg.mic = 'auto' }
    return $cfg
}

function Save-Config {
    $obj = [ordered]@{ mode = $script:Mode; host = $HOST_IP; port = $PORT; hotkeys = $VK_LIST; mic = $script:MicPref; overlay = $script:OverlayEnabled; mdns = $script:MdnsEnabled; hosts = @($script:Hosts) }
    try { ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $global:ConfigPath -Encoding UTF8 } catch {}
}

$cfg      = Load-Config
$HOST_IP  = $cfg.host
$PORT     = [int]$cfg.port
$VK_LIST  = @($cfg.hotkeys)
$script:Mode           = $cfg.mode
$script:MicPref        = $cfg.mic
$script:OverlayEnabled = [bool]$cfg.overlay
$script:MdnsEnabled    = [bool]$cfg.mdns
$script:Hosts          = @($cfg.hosts)
# Always keep the currently-configured host in the candidate list.
if ($HOST_IP -and (@($script:Hosts) -notcontains $HOST_IP)) { $script:Hosts += $HOST_IP }
$script:isListening    = $false
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
$global:IconConnected    = New-CircleIcon ([System.Drawing.Color]::FromArgb(67, 190, 120))  # green  = connected
$global:IconDisconnected = New-CircleIcon ([System.Drawing.Color]::FromArgb(130, 130, 135)) # grey   = not connected
$global:IconRec          = New-CircleIcon ([System.Drawing.Color]::FromArgb(229, 57, 53))   # red    = dictating

# --- System tray ---------------------------------------------------------------
$script:menu       = New-Object System.Windows.Forms.ContextMenuStrip
$script:itemStatus = New-Object System.Windows.Forms.ToolStripMenuItem 'Status: Ready'
$script:itemStatus.Enabled = $false
$script:itemServer = New-Object System.Windows.Forms.ToolStripMenuItem 'Server: -'
$script:itemServer.Enabled = $false
$script:itemMic    = New-Object System.Windows.Forms.ToolStripMenuItem 'Mic: -'
$script:itemMic.Enabled = $false
$script:itemAudio  = New-Object System.Windows.Forms.ToolStripMenuItem 'Audio: -'
$script:itemAudio.Enabled = $false
$script:itemToggle = New-Object System.Windows.Forms.ToolStripMenuItem 'Mode: Toggle (tap to start/stop)'
$script:itemPTT    = New-Object System.Windows.Forms.ToolStripMenuItem 'Mode: Push-to-Talk (hold to talk)'
$script:itemExit   = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit Hermes'

$script:menuMic  = New-Object System.Windows.Forms.ToolStripMenuItem 'Microphone'
$script:micAuto  = New-Object System.Windows.Forms.ToolStripMenuItem 'Auto (Bluetooth, else phone)'
$script:micPhone = New-Object System.Windows.Forms.ToolStripMenuItem 'Phone (built-in mic)'
$script:micBt    = New-Object System.Windows.Forms.ToolStripMenuItem 'Bluetooth headset'
$script:menuMic.DropDownItems.Add($script:micAuto)  | Out-Null
$script:menuMic.DropDownItems.Add($script:micPhone) | Out-Null
$script:menuMic.DropDownItems.Add($script:micBt)    | Out-Null

$script:itemOverlay = New-Object System.Windows.Forms.ToolStripMenuItem 'Show dictation overlay'
$script:itemMdns    = New-Object System.Windows.Forms.ToolStripMenuItem 'Auto-discover (mDNS)'

# Transport submenu: one checkable entry per configured endpoint, plus Add/Edit/Remove actions so
# IPs can be changed at runtime for different networks. Populated by Rebuild-TransportMenu at
# startup, once its helper functions are defined.
$script:menuTransport = New-Object System.Windows.Forms.ToolStripMenuItem 'Server'

$script:itemToggle.Add_Click({ Set-Mode 'Toggle' })
$script:itemPTT.Add_Click({ Set-Mode 'PushToTalk' })
$script:micAuto.Add_Click({ Set-MicPref 'auto' })
$script:micPhone.Add_Click({ Set-MicPref 'builtin' })
$script:micBt.Add_Click({ Set-MicPref 'bluetooth' })
$script:itemOverlay.Add_Click({ Set-OverlayEnabled (-not $script:OverlayEnabled) })
$script:itemMdns.Add_Click({ Set-MdnsEnabled (-not $script:MdnsEnabled) })
$script:itemExit.Add_Click({ $script:ShouldExit = $true })

$script:menu.Items.Add($script:itemStatus) | Out-Null
$script:menu.Items.Add($script:itemServer) | Out-Null
$script:menu.Items.Add($script:itemMic) | Out-Null
$script:menu.Items.Add($script:itemAudio) | Out-Null
$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$script:menu.Items.Add($script:itemToggle) | Out-Null
$script:menu.Items.Add($script:itemPTT) | Out-Null
$script:menu.Items.Add($script:menuMic) | Out-Null
$script:menu.Items.Add($script:menuTransport) | Out-Null
$script:menu.Items.Add($script:itemOverlay) | Out-Null
$script:menu.Items.Add($script:itemMdns) | Out-Null
$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$script:menu.Items.Add($script:itemExit) | Out-Null

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = $global:IconDisconnected
$script:notify.Text = 'Project Hermes - Disconnected'
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

function Update-MicChecks {
    $script:micAuto.Checked  = ($script:MicPref -eq 'auto')
    $script:micPhone.Checked = ($script:MicPref -eq 'builtin')
    $script:micBt.Checked    = ($script:MicPref -eq 'bluetooth')
}

function Update-OverlayCheck { $script:itemOverlay.Checked = $script:OverlayEnabled }

# Toggle the on-screen dictation overlay (REQ-FUNC-014) and persist the choice. Disabling hides any
# overlay currently on screen; the setting takes effect on the next dictation when enabling.
function Set-OverlayEnabled([bool]$on) {
    $script:OverlayEnabled = $on
    Update-OverlayCheck
    Save-Config
    if (-not $on) { Hide-Overlay }
    Write-Log "Dictation overlay: $(if ($on) { 'enabled' } else { 'disabled' })" 'Cyan'
}

function Update-MdnsCheck { $script:itemMdns.Checked = $script:MdnsEnabled }

# Toggle mDNS auto-discovery. When on, the connect cycle queries _hermes._tcp first, then falls
# back to the configured transport endpoints.
function Set-MdnsEnabled([bool]$on) {
    $script:MdnsEnabled = $on
    Update-MdnsCheck
    Save-Config
    Write-Log "mDNS auto-discovery: $(if ($on) { 'enabled' } else { 'disabled' })" 'Cyan'
}

# Tell the phone which microphone to use. Applies to the next dictation; remembered on the phone.
function Send-SetMic($m) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $json = "{`"version`":`"1.0`",`"type`":`"command`",`"command`":`"set_mic`",`"mic`":`"$m`",`"timestamp`":$ts}"
    try { if ($global:writer) { $global:writer.WriteLine($json) } } catch {}
}

function Set-MicPref($m) {
    $script:MicPref = $m
    Update-MicChecks
    Save-Config
    Send-SetMic $m
    Write-Log "Microphone preference: $m" 'Cyan'
}

function Update-TransportChecks {
    foreach ($item in $script:menuTransport.DropDownItems) {
        # Only the endpoint items carry a Tag with a Host; skip the separator and Add/Edit/Remove.
        if ($item -is [System.Windows.Forms.ToolStripMenuItem] -and $item.Tag -and $item.Tag.Host) {
            $item.Checked = ($item.Tag.Host -eq $script:HOST_IP)
        }
    }
}

# Switch the active server IP and reconnect live (no restart): drop the current socket and reset
# the backoff so the main loop's Ensure-Connected immediately dials the new host.
function Set-Transport($hostIp) {
    $script:HOST_IP = [string]$hostIp
    Update-TransportChecks
    $script:itemServer.Text = "Server: ${HOST_IP}:${PORT} (switching...)"
    Save-Config
    Write-Log "Server -> $hostIp; reconnecting..." 'Cyan'
    Close-Transport
    Set-ListeningState $false
    Hide-Overlay
    $script:BackoffMs = $script:BackoffMinMs
    $script:NextConnectAt = 0
    $script:AnnouncedConnecting = $false
}

# (Re)build the Server submenu from the plain IP list ($script:Hosts) plus Add/Edit/Remove actions.
function Rebuild-TransportMenu {
    $script:menuTransport.DropDownItems.Clear()
    foreach ($h in @($script:Hosts)) {
        $hs = [string]$h
        if (-not $hs) { continue }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $hs
        $item.Tag = @{ Host = $hs }
        $item.Add_Click({ param($s, $e) Set-Transport $s.Tag.Host })
        [void]$script:menuTransport.DropDownItems.Add($item)
    }
    [void]$script:menuTransport.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miAdd = New-Object System.Windows.Forms.ToolStripMenuItem 'Add server IP...'
    $miAdd.Add_Click({ Add-TransportEndpoint })
    [void]$script:menuTransport.DropDownItems.Add($miAdd)
    $miEdit = New-Object System.Windows.Forms.ToolStripMenuItem 'Edit current IP...'
    $miEdit.Add_Click({ Edit-CurrentEndpoint })
    [void]$script:menuTransport.DropDownItems.Add($miEdit)
    $miRm = New-Object System.Windows.Forms.ToolStripMenuItem 'Remove current IP'
    $miRm.Add_Click({ Remove-TransportEndpoint })
    [void]$script:menuTransport.DropDownItems.Add($miRm)
    Update-TransportChecks
}

# Add a server IP and switch to it. Lets you use a new network without editing the config file.
function Add-TransportEndpoint {
    $ip = [Microsoft.VisualBasic.Interaction]::InputBox('Server IP address:', 'Hermes - add server IP', '')
    if ([string]::IsNullOrWhiteSpace($ip)) { return }
    $ip = $ip.Trim()
    if (@($script:Hosts) -notcontains $ip) { $script:Hosts += $ip }
    Save-Config
    Rebuild-TransportMenu
    Set-Transport $ip
}

# Change the currently-selected server IP (e.g. the phone's IP on a different network).
function Edit-CurrentEndpoint {
    $ip = [Microsoft.VisualBasic.Interaction]::InputBox('New server IP address:', 'Hermes - edit server IP', $script:HOST_IP)
    if ([string]::IsNullOrWhiteSpace($ip)) { return }
    $ip = $ip.Trim()
    $script:Hosts = @(@($script:Hosts) | ForEach-Object { if ($_ -eq $script:HOST_IP) { $ip } else { $_ } })
    if (@($script:Hosts) -notcontains $ip) { $script:Hosts += $ip }
    Save-Config
    Rebuild-TransportMenu
    Set-Transport $ip
}

# Remove the currently-selected server IP and switch to the first remaining one.
function Remove-TransportEndpoint {
    $remaining = @(@($script:Hosts) | Where-Object { $_ -ne $script:HOST_IP })
    if ($remaining.Count -eq 0) { Write-Log 'Cannot remove the only server IP.' 'DarkYellow'; return }
    $removed = $script:HOST_IP
    $script:Hosts = $remaining
    Save-Config
    Rebuild-TransportMenu
    Set-Transport ([string]$remaining[0])
    Write-Log "Removed server IP '$removed'." 'Cyan'
}

# Tray icon reflects the true state: red while dictating, else green when connected to the phone,
# else grey. "Connected" is the same live-socket test Ensure-Connected uses.
function Update-TrayIcon {
    $connected = ($global:tcpClient -and $global:tcpClient.Connected)
    if ($script:isListening) {
        $script:notify.Icon = $global:IconRec
        $script:notify.Text = 'Project Hermes - Listening...'
    } elseif ($connected) {
        $script:notify.Icon = $global:IconConnected
        $script:notify.Text = "Project Hermes - Connected ($script:Mode)"
    } else {
        $script:notify.Icon = $global:IconDisconnected
        $script:notify.Text = 'Project Hermes - Disconnected'
    }
}

function Set-ListeningState($listening) {
    $script:isListening = $listening
    $script:itemStatus.Text = if ($listening) { 'Status: Listening...' } else { 'Status: Ready' }
    Update-TrayIcon
}
Update-ModeChecks
Update-MicChecks
Update-OverlayCheck
Update-MdnsCheck
Rebuild-TransportMenu

# --- Dictation overlay (HUD, REQ-FUNC-014) -------------------------------------
# A dark, semi-transparent bar at the bottom-centre of the primary screen that visualises a live
# dictation: a pulsing indicator + "Listening…" on start, the running partial transcript as words
# are detected, then a green tick + the final transcript at the moment it is injected, before
# fading out. The window is passive (see Hermes.OverlayForm above): it never activates, never
# appears in the taskbar, and is click-through, so it cannot disturb the caret or the paste target.
# All updates run on the main-loop thread (Process-HermesLine / Start-/Stop-Dictation), the same
# thread as the WinForms message pump, so no cross-thread marshalling is needed.

$script:overlay        = $null      # Hermes.OverlayForm instance (created lazily)
$script:ovTimer        = $null      # animation + fade ticker
$script:ovMeasureG     = $null      # offscreen Graphics used to measure wrapped text height
$script:ovFont         = $null      # transcript font
$script:ovLabelFont    = $null      # state-label font
$script:ovState        = 'Idle'     # Idle | Listening | Finalizing | Final | Error | Info
$script:ovText         = ''         # current transcript / message
$script:ovPulse        = 0          # animation phase counter
$script:ovOpacityTarget= 0.0        # opacity the fader eases towards
$script:ovHideAt       = 0          # TickCount to begin auto-hide (0 = not scheduled)

$script:OV_OPACITY = 0.93
$script:OV_PADX    = 18
$script:OV_PADY    = 13
$script:OV_DOT     = 12
$script:OV_GAP     = 12
$script:OV_RADIUS  = 16
$script:ovBackColor = [System.Drawing.Color]::FromArgb(24, 24, 27)
$script:ovTextColor = [System.Drawing.Color]::FromArgb(244, 244, 246)
$script:ovDimColor  = [System.Drawing.Color]::FromArgb(158, 158, 165)

function New-RoundedRegion([int]$w, [int]$h, [int]$r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d, $d, $d, 90, 90)
    $path.CloseAllFigures()
    $region = New-Object System.Drawing.Region($path)
    $path.Dispose()
    return $region
}

function Get-OverlayLabel {
    switch ($script:ovState) {
        'Listening'  { 'Listening…' }
        'Finalizing'   { 'Transcribing…' }
        'Disconnected' { 'Not connected' }
        'Error'        { 'Error' }
        default      { '' }        # Final / Info / Idle carry no label
    }
}

function Get-OverlayDotColor {
    switch ($script:ovState) {
        'Listening'  { [System.Drawing.Color]::FromArgb(229, 57, 53) }   # red (matches tray rec icon)
        'Finalizing' { [System.Drawing.Color]::FromArgb(255, 179, 0) }   # amber
        'Final'      { [System.Drawing.Color]::FromArgb(67, 190, 120) }  # green
        'Error'      { [System.Drawing.Color]::FromArgb(229, 57, 53) }   # red
        default      { [System.Drawing.Color]::FromArgb(130, 130, 135) } # grey (Info/Idle)
    }
}

function Initialize-Overlay {
    if ($script:overlay) { return }
    $script:ovFont      = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular)
    $script:ovLabelFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $bmp = New-Object System.Drawing.Bitmap 1, 1
    $script:ovMeasureG = [System.Drawing.Graphics]::FromImage($bmp)

    $f = New-Object Hermes.OverlayForm
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.BackColor       = $script:ovBackColor
    $f.Opacity         = 0.0
    $f.Add_Paint({ param($sender, $e) Draw-Overlay $e.Graphics })
    $script:overlay = $f

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 60
    $t.Add_Tick({ Step-Overlay })
    $script:ovTimer = $t
}

# Measure the wrapped transcript, size the bar to fit, and re-centre it near the bottom of the
# primary working area (above the taskbar). Called whenever the state or text changes.
function Update-OverlayBounds {
    if (-not $script:overlay) { return }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = [int][Math]::Min(560, $wa.Width * 0.6)
    if ($width -lt 320) { $width = 320 }
    $textX = $script:OV_PADX + $script:OV_DOT + $script:OV_GAP
    $textW = $width - $textX - $script:OV_PADX

    $contentH = 0
    $label = Get-OverlayLabel
    if ($label -ne '') {
        $contentH += [int][Math]::Ceiling($script:ovMeasureG.MeasureString($label, $script:ovLabelFont).Height) + 2
    }
    if ($script:ovText -ne '') {
        $sz = $script:ovMeasureG.MeasureString($script:ovText, $script:ovFont, [int]$textW)
        $contentH += [int][Math]::Ceiling($sz.Height) + 4
    } else {
        $contentH += [int][Math]::Ceiling($script:ovMeasureG.MeasureString('Ag', $script:ovFont).Height)
    }
    $height = $contentH + ($script:OV_PADY * 2)
    if ($height -lt 52) { $height = 52 }

    $x = $wa.Left + [int](($wa.Width - $width) / 2)
    $y = $wa.Bottom - $height - 120
    $script:overlay.SetBounds($x, $y, $width, $height)
    $script:overlay.Region = New-RoundedRegion $width $height $script:OV_RADIUS
}

function Draw-Overlay($g) {
    if (-not $script:overlay) { return }
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $w = $script:overlay.ClientSize.Width
    $h = $script:overlay.ClientSize.Height

    $bgBrush = New-Object System.Drawing.SolidBrush $script:ovBackColor
    $g.FillRectangle($bgBrush, 0, 0, $w, $h)
    $bgBrush.Dispose()

    # Status dot; alpha pulses while listening so the user sees the app is actively capturing.
    $base = Get-OverlayDotColor
    $alpha = 255
    if ($script:ovState -eq 'Listening') {
        $phase = [Math]::Sin($script:ovPulse * 0.35)   # ~1.1s period at 60ms ticks
        $alpha = [int](172 + 83 * $phase)
        if ($alpha -lt 60)  { $alpha = 60 }
        if ($alpha -gt 255) { $alpha = 255 }
    }
    $dotColor = [System.Drawing.Color]::FromArgb($alpha, $base.R, $base.G, $base.B)
    $dotBrush = New-Object System.Drawing.SolidBrush $dotColor
    $dotY = $script:OV_PADY + 3
    $g.FillEllipse($dotBrush, $script:OV_PADX, $dotY, $script:OV_DOT, $script:OV_DOT)
    $dotBrush.Dispose()

    # A white tick over the green dot confirms the final transcript was produced/injected.
    if ($script:ovState -eq 'Final') {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
        $cx = $script:OV_PADX; $cy = $dotY
        # Typed PointF[] so DrawLines binds the PointF (not Point) overload unambiguously.
        $pts = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF([single]($cx + 2.5), [single]($cy + 6.5))),
            (New-Object System.Drawing.PointF([single]($cx + 5.0), [single]($cy + 9.0))),
            (New-Object System.Drawing.PointF([single]($cx + 9.5), [single]($cy + 3.0)))
        )
        $g.DrawLines($pen, $pts)
        $pen.Dispose()
    }

    $textX = $script:OV_PADX + $script:OV_DOT + $script:OV_GAP
    $textW = $w - $textX - $script:OV_PADX
    $curY  = $script:OV_PADY

    $label = Get-OverlayLabel
    if ($label -ne '') {
        $lblBrush = New-Object System.Drawing.SolidBrush $script:ovDimColor
        $g.DrawString($label, $script:ovLabelFont, $lblBrush, [single]$textX, [single]$curY)
        $curY += [int][Math]::Ceiling($g.MeasureString($label, $script:ovLabelFont).Height) + 2
        $lblBrush.Dispose()
    }

    if ($script:ovText -ne '') {
        $txtColor = if ($script:ovState -eq 'Final') { [System.Drawing.Color]::FromArgb(215, 245, 222) } else { $script:ovTextColor }
        $txtBrush = New-Object System.Drawing.SolidBrush $txtColor
        $rect = New-Object System.Drawing.RectangleF([single]$textX, [single]$curY, [single]$textW, [single]($h - $curY - $script:OV_PADY))
        $g.DrawString($script:ovText, $script:ovFont, $txtBrush, $rect)
        $txtBrush.Dispose()
    }
}

# Runs every ~60ms while the overlay is on screen: advances the pulse, eases opacity toward its
# target (fade in/out), triggers a scheduled auto-hide, and parks (hides + stops the timer) once
# fully faded so the client consumes no cycles when idle.
function Step-Overlay {
    if (-not $script:overlay) { return }
    $script:ovPulse++

    if ($script:ovHideAt -ne 0 -and [Environment]::TickCount -ge $script:ovHideAt) {
        $script:ovOpacityTarget = 0.0
    }

    $cur = [double]$script:overlay.Opacity
    $target = [double]$script:ovOpacityTarget
    if ([Math]::Abs($cur - $target) -lt 0.02) {
        $cur = $target
    } elseif ($cur -lt $target) {
        $cur = [Math]::Min($target, $cur + 0.30)   # fade in over ~3 ticks
    } else {
        $cur = [Math]::Max($target, $cur - 0.12)   # fade out over ~8 ticks (~0.5s)
    }
    if ($cur -ne [double]$script:overlay.Opacity) { $script:overlay.Opacity = $cur }

    if ($target -le 0.0 -and $cur -le 0.001) {
        try { $script:overlay.Hide() } catch {}
        $script:ovState  = 'Idle'
        $script:ovText   = ''
        $script:ovHideAt = 0
        $script:ovTimer.Stop()
        return
    }

    # Repaint only while something is actually moving (pulse or fade) to keep CPU near zero.
    if ($script:ovState -eq 'Listening' -or $script:ovState -eq 'Finalizing' -or $cur -ne $target) {
        $script:overlay.Invalidate()
    }
}

function Show-OverlayWindow {
    if (-not $script:overlay.Visible) {
        $script:overlay.Show()
        # Force a no-activate show regardless of WinForms internals (SW_SHOWNOACTIVATE = 4), so the
        # overlay never becomes foreground and the dictation target keeps focus.
        try { [Win32Input]::ShowWindow($script:overlay.Handle, 4) | Out-Null } catch {}
    }
    if (-not $script:ovTimer.Enabled) { $script:ovTimer.Start() }
}

# Enter a live state ('Listening' clears any prior text; 'Finalizing' keeps the last partial).
function Show-Overlay([string]$state) {
    if (-not $script:OverlayEnabled) { return }
    Initialize-Overlay
    if ($state -eq 'Listening') { $script:ovText = '' }
    $script:ovState = $state
    # Safety net: if no 'final' ever arrives (link dropped after stop, hotkey pressed while
    # disconnected, …) the bar must not hang on "Transcribing…" forever. A real final overrides
    # this the moment it lands. 'Listening' is held by the user, so it never auto-hides.
    $script:ovHideAt        = if ($state -eq 'Finalizing') { [Environment]::TickCount + 10000 } else { 0 }
    $script:ovOpacityTarget = $script:OV_OPACITY
    Update-OverlayBounds
    Show-OverlayWindow
    $script:overlay.Invalidate()
}

# Update the running transcript from a partial result (ignored once finalising has completed).
function Set-OverlayText([string]$text) {
    if (-not $script:OverlayEnabled -or -not $script:overlay) { return }
    if ($script:ovState -ne 'Listening' -and $script:ovState -ne 'Finalizing') { return }
    $script:ovText = [string]$text
    Update-OverlayBounds
    $script:overlay.Invalidate()
}

function Set-OverlayFinal([string]$text) {
    if (-not $script:OverlayEnabled) { return }
    Initialize-Overlay
    $script:ovState         = 'Final'
    $script:ovText          = [string]$text
    $script:ovOpacityTarget = $script:OV_OPACITY
    $script:ovHideAt        = [Environment]::TickCount + 1500
    Update-OverlayBounds
    Show-OverlayWindow
    $script:overlay.Invalidate()
}

# Brief neutral message (e.g. no speech captured) that fades on its own.
function Set-OverlayInfo([string]$text) {
    if (-not $script:OverlayEnabled) { return }
    Initialize-Overlay
    $script:ovState         = 'Info'
    $script:ovText          = [string]$text
    $script:ovOpacityTarget = $script:OV_OPACITY
    $script:ovHideAt        = [Environment]::TickCount + 1400
    Update-OverlayBounds
    Show-OverlayWindow
    $script:overlay.Invalidate()
}

function Set-OverlayError([string]$msg) {
    if (-not $script:OverlayEnabled) { return }
    Initialize-Overlay
    $script:ovState         = 'Error'
    $script:ovText          = [string]$msg
    $script:ovOpacityTarget = $script:OV_OPACITY
    $script:ovHideAt        = [Environment]::TickCount + 2500
    Update-OverlayBounds
    Show-OverlayWindow
    $script:overlay.Invalidate()
}

# Shown when dictation is attempted while the phone is not connected (grey dot, "Not connected").
function Set-OverlayDisconnected([string]$msg) {
    if (-not $script:OverlayEnabled) { return }
    Initialize-Overlay
    $script:ovState         = 'Disconnected'
    $script:ovText          = [string]$msg
    $script:ovOpacityTarget = $script:OV_OPACITY
    $script:ovHideAt        = [Environment]::TickCount + 2500
    Update-OverlayBounds
    Show-OverlayWindow
    $script:overlay.Invalidate()
}

# Begin an immediate fade-out (the ticker parks the window once hidden). Safe to call when the
# overlay was never created or is already hidden.
function Hide-Overlay {
    if (-not $script:overlay) { return }
    $script:ovHideAt        = 0
    $script:ovOpacityTarget = 0.0
    if (-not $script:ovTimer.Enabled) { $script:ovTimer.Start() }
}

# Pump the WinForms message loop for $ms so overlay timers (pulse/fade) tick, mirroring how the live
# main loop drives them via Application.DoEvents. Used only by the -Preview dev mode.
function Wait-Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
}

# Dev-only: a scripted dictation that exercises the real overlay functions (no phone / no TCP).
function Start-OverlayPreview {
    $script:OverlayEnabled = $true
    Write-Log 'Overlay preview: scripted dictation starting…' 'Cyan'
    Show-Overlay 'Listening'
    Wait-Pump 900
    $acc = ''
    foreach ($word in 'create a python class that reads a config file and validates each field'.Split(' ')) {
        $acc = ($acc + ' ' + $word).Trim()
        Set-OverlayText $acc
        Wait-Pump 220
    }
    Show-Overlay 'Finalizing'
    Wait-Pump 700
    Set-OverlayFinal 'Create a Python class that reads a config file and validates each field.'
    Wait-Pump 3200   # hold the final, then let it auto-fade and park
    Write-Log 'Overlay preview: done.' 'Cyan'
}

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
    Update-TrayIcon   # reflect the now-disconnected state (grey) unless dictating
}

function Try-Connect($tryHost) {
    # Non-blocking connect to $tryHost bounded by $script:ConnectTimeoutMs. Unlike the blocking
    # TcpClient(host, port) constructor -- which parks the WinForms message pump for the full
    # ~20s OS timeout on an unreachable host (the original tray "freeze") -- this drives
    # BeginConnect and pumps DoEvents while it waits, so the tray stays responsive.
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    try {
        $iar = $client.BeginConnect($tryHost, $PORT, $null, $null)
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
    $script:itemServer.Text = "Server: ${tryHost}:${PORT} (connected)"
    Send-SetMic $script:MicPref   # sync the mic preference to the phone on (re)connect
    Write-Log "Connected to Android transport server at ${tryHost}:${PORT}" 'Green'
    return $true
}

# --- mDNS (DNS-SD) discovery of the phone ------------------------------------
# Advance past a DNS name at [pos], handling label sequences and 0xC0 compression pointers.
function Skip-DnsName([byte[]]$buf, [int]$pos) {
    while ($pos -lt $buf.Length) {
        $len = $buf[$pos]
        if ($len -eq 0) { return $pos + 1 }
        if (($len -band 0xC0) -eq 0xC0) { return $pos + 2 }
        $pos += 1 + $len
    }
    return $pos
}

# Return ALL IPv4 (A record) addresses found in a DNS/mDNS response. A multi-homed phone lists
# every interface IP (Wi-Fi, tether, tunnel); we try them all rather than guessing the first.
function Get-AllARecords([byte[]]$buf) {
    $ips = New-Object System.Collections.Generic.List[string]
    if ($buf.Length -lt 12) { return $ips }
    $qd  = ($buf[4] -shl 8) -bor $buf[5]
    $rec = (($buf[6] -shl 8) -bor $buf[7]) + (($buf[8] -shl 8) -bor $buf[9]) + (($buf[10] -shl 8) -bor $buf[11])
    $pos = 12
    for ($i = 0; $i -lt $qd; $i++) { $pos = Skip-DnsName $buf $pos; $pos += 4 }
    for ($i = 0; $i -lt $rec; $i++) {
        $pos = Skip-DnsName $buf $pos
        if (($pos + 10) -gt $buf.Length) { break }
        $type  = ($buf[$pos] -shl 8) -bor $buf[$pos + 1]
        $rdlen = ($buf[$pos + 8] -shl 8) -bor $buf[$pos + 9]
        $pos += 10
        if ($type -eq 1 -and $rdlen -eq 4 -and ($pos + 4) -le $buf.Length) {
            $ip = "$($buf[$pos]).$($buf[$pos+1]).$($buf[$pos+2]).$($buf[$pos+3])"
            if ($ip -ne '0.0.0.0' -and -not $ips.Contains($ip)) { $ips.Add($ip) }
        }
        $pos += $rdlen
    }
    return $ips
}

# Query mDNS for _hermes._tcp.local and return the phone's advertised IPv4 addresses (may be
# several on a multi-homed phone). Uses the QU (unicast-response) bit so the reply comes back to
# our ephemeral port (no 5353 bind / group join needed). Best-effort: failure/timeout -> empty.
function Resolve-HermesMdns {
    $found = New-Object System.Collections.Generic.List[string]
    $udp = $null
    try {
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        foreach ($b in @(0,0, 0,0, 0,1, 0,0, 0,0, 0,0)) { $bw.Write([byte]$b) }   # header: 1 question
        foreach ($label in @('_hermes','_tcp','local')) {
            $lb = [System.Text.Encoding]::ASCII.GetBytes($label)
            $bw.Write([byte]$lb.Length); $bw.Write($lb)
        }
        $bw.Write([byte]0)                          # end of QNAME
        $bw.Write([byte]0);    $bw.Write([byte]12)  # QTYPE  = PTR (12)
        $bw.Write([byte]0x80); $bw.Write([byte]1)   # QCLASS = IN with QU (unicast-response) bit
        $bw.Flush()
        $query = $ms.ToArray()

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.ReceiveTimeout = 300
        $mcast = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('224.0.0.251'), 5353)
        [void]$udp.Send($query, $query.Length, $mcast)

        $deadline = [Environment]::TickCount + 900
        while ([Environment]::TickCount -lt $deadline) {
            try {
                $remote = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
                $resp = $udp.Receive([ref]$remote)
            } catch { break }   # ReceiveTimeout -> stop waiting
            $recs = Get-AllARecords $resp
            if ($recs.Count -gt 0) {
                foreach ($ip in $recs) { if (-not $found.Contains($ip)) { $found.Add($ip) } }
                break   # first response with A records usually lists all of the phone's addresses
            }
        }
    } catch {
        # setup/socket error -> no result
    } finally {
        try { if ($udp) { $udp.Close() } } catch {}
    }
    return $found
}

# Ordered, de-duplicated connect candidates: every mDNS-discovered IP first (if enabled), then the
# configured host list, then the current host as a final fallback. Try-Connect picks the reachable one.
function Get-ConnectCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    if ($script:MdnsEnabled) {
        foreach ($m in Resolve-HermesMdns) {
            $s = [string]$m
            if ($s -and -not $list.Contains($s)) { $list.Add($s) }
        }
        if ($list.Count -gt 0) { Write-Log "mDNS discovered: $($list -join ', ')" 'DarkCyan' }
    }
    foreach ($h in @($script:Hosts)) {
        $s = [string]$h
        if ($s -and -not $list.Contains($s)) { $list.Add($s) }
    }
    if ($script:HOST_IP -and -not $list.Contains([string]$script:HOST_IP)) { $list.Add([string]$script:HOST_IP) }
    return $list
}

function Ensure-Connected {
    # Called once per main-loop iteration. Non-blocking: returns immediately while backing off, and
    # makes at most one connect cycle per interval, so an unreachable phone never freezes the tray.
    # A cycle tries mDNS first, then each configured endpoint, connecting to the first that answers.
    if ($global:tcpClient -and $global:tcpClient.Connected) { return $true }
    if ([Environment]::TickCount -lt $script:NextConnectAt) { return $false }

    if (-not $script:AnnouncedConnecting) {
        Write-Log "Connecting to the phone (mDNS, then configured transports; auto-retrying)..." 'DarkYellow'
        $script:AnnouncedConnecting = $true
    }
    if (-not $script:isListening) { $script:itemStatus.Text = 'Status: Connecting...' }

    foreach ($cand in Get-ConnectCandidates) {
        if ($script:ShouldExit) { break }
        $script:itemServer.Text = "Server: ${cand}:${PORT} (connecting...)"
        if (Try-Connect $cand) {
            $script:HOST_IP = $cand
            $script:BackoffMs = $script:BackoffMinMs
            $script:AnnouncedConnecting = $false
            Update-TransportChecks
            Update-TrayIcon
            if (-not $script:isListening) { $script:itemStatus.Text = 'Status: Ready' }
            return $true
        }
    }

    $script:NextConnectAt = [Environment]::TickCount + $script:BackoffMs
    $script:BackoffMs = [Math]::Min($script:BackoffMs * 2, $script:BackoffMaxMs)
    Update-TrayIcon
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
    # Do NOT SW_RESTORE unconditionally: on a *maximized* target that un-maximizes it (the window
    # appears to "minimize"/shrink right after paste). A *minimized* target was already restored
    # above (guarded by IsIconic); a maximized/normal target is brought forward by SetForegroundWindow.
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
    # Never show "Listening" when the phone isn't connected -- nothing can be dictated. Indicate
    # the connection state in the overlay instead and bail out. (fix 2)
    if (-not ($global:tcpClient -and $global:tcpClient.Connected)) {
        Set-OverlayDisconnected 'Not connected to phone'
        Write-Log 'Dictation ignored: not connected to the phone.' 'DarkYellow'
        return
    }
    $fg = [Win32Input]::GetForegroundWindow()
    if ($fg.ToInt64() -ne 0 -and $fg.ToInt64() -ne $script:consoleHwnd.ToInt64()) {
        $script:targetHwnd = $fg
        Write-Log "Target window: $(Get-WindowTitle $fg)" 'DarkCyan'
    } else {
        $script:targetHwnd = [IntPtr]::Zero
    }
    Set-ListeningState $true
    Send-HermesCommand 'start_listening'
    Show-Overlay 'Listening'   # target window already captured above; overlay never takes focus
    Write-Log 'Listening started.' 'Red'
}

function Stop-Dictation {
    if (-not $script:isListening) { return }
    Set-ListeningState $false
    Send-HermesCommand 'stop_listening'
    Show-Overlay 'Finalizing'   # keep the last partial visible while the final transcript arrives
    Write-Log 'Listening stopped; awaiting transcript.' 'Yellow'
}

function Process-HermesLine($line) {
    if (-not $line -or $line.Trim().Length -eq 0) { return }
    try {
        $msg = $line | ConvertFrom-Json
        switch ($msg.type) {
            'partial' {
                Write-Log "  partial: $($msg.text)" 'DarkGray'
                Set-OverlayText ([string]$msg.text)   # live running transcript in the HUD
            }
            'final' {
                $ftext = $msg.text
                Write-Log "Transcript: $ftext" 'Green'
                if ($ftext -and $ftext.Trim().Length -gt 0) {
                    Set-OverlayFinal ($ftext.Trim())   # confirm the produced text before injecting it
                    # Append a trailing space so consecutive dictations stay separated.
                    Set-WindowsTextClipboard ($ftext.TrimEnd() + ' ')
                    Start-Sleep -Milliseconds 100
                    Send-Win32Paste
                } else {
                    Set-OverlayInfo 'No speech detected'
                }
            }
            'error'     {
                Write-Log "Speech error: $($msg.message) (Code: $($msg.code))" 'Red'
                Set-OverlayError ([string]$msg.message)
            }
            'status'    {
                # Diagnostics from the phone: which mic is engaged, whether audio was detected, etc.
                if ($msg.mic) {
                    $micLabel = [string]$msg.mic
                    if ($msg.device) { $micLabel = "$micLabel ($($msg.device))" }
                    $script:itemMic.Text = "Mic: $micLabel"
                }
                switch ([string]$msg.event) {
                    'speech_detected' { $script:itemAudio.Text = 'Audio: detected' }
                    'no_speech'       { $script:itemAudio.Text = 'Audio: none captured' }
                    'mic_fallback'    { $script:itemAudio.Text = 'Audio: BT silent, using built-in'; $script:itemMic.Text = 'Mic: builtin' }
                    'mic'             { $script:itemAudio.Text = 'Audio: -' }
                }
                $detail = if ($msg.detail) { [string]$msg.detail } else { [string]$msg.event }
                Write-Log "Diagnostic: $detail" 'DarkCyan'
            }
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

# Dev preview mode: drive the overlay through a scripted dictation, then exit without the tray loop.
if ($Preview) {
    Start-OverlayPreview
    try { if ($script:ovTimer) { $script:ovTimer.Stop(); $script:ovTimer.Dispose() } } catch {}
    try { if ($script:overlay) { $script:overlay.Dispose() } } catch {}
    try { $script:notify.Visible = $false; $script:notify.Dispose() } catch {}
    return
}

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
            $script:itemServer.Text = "Server: ${HOST_IP}:${PORT} (disconnected)"
            [void]$global:recvBuffer.Clear()
            Set-ListeningState $false
            Hide-Overlay   # a dropped link mid-dictation yields no transcript; clear the HUD
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
try { if ($script:ovTimer)     { $script:ovTimer.Stop(); $script:ovTimer.Dispose() } } catch {}
try { if ($script:overlay)     { $script:overlay.Close(); $script:overlay.Dispose() } } catch {}
try { if ($script:ovFont)      { $script:ovFont.Dispose() } } catch {}
try { if ($script:ovLabelFont) { $script:ovLabelFont.Dispose() } } catch {}
try { if ($script:ovMeasureG)  { $script:ovMeasureG.Dispose() } } catch {}
try { if ($global:writer) { $global:writer.Dispose() } } catch {}
try { if ($global:stream) { $global:stream.Dispose() } } catch {}
try { if ($global:tcpClient) { $global:tcpClient.Close() } } catch {}
