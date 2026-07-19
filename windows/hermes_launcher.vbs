' Project Hermes - hidden launcher.
' Starts the PowerShell companion daemon with no console window so it lives quietly
' in the system tray. Double-click this file, or let the installer auto-start it at logon.
Option Explicit
Dim shell, scriptDir, ps1, cmd
Set shell = CreateObject("WScript.Shell")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps1 = scriptDir & "hermes_hotkey.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
' Second argument 0 = hidden window; third False = do not wait.
shell.Run cmd, 0, False
