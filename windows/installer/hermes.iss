; Project Hermes - Inno Setup installer
; ---------------------------------------------------------------------------
; Builds a per-user Setup.exe that installs the tray companion to
; %LOCALAPPDATA%\ProjectHermes, auto-starts it at logon, adds a Start-menu entry,
; and merges hermes.config.json (preserves host/port; sets PushToTalk + Right Ctrl).
;
; Build with Inno Setup 6:   ISCC.exe hermes.iss    (or: task windows:installer:build)
; Output:                    ..\dist\ProjectHermes-Setup.exe
; See README.md in this folder for prerequisites.
; ---------------------------------------------------------------------------

#define AppName "Project Hermes"
#define AppVersion "1.0.0"

[Setup]
AppId={{A1B2C3D4-E5F6-47A8-9B0C-1D2E3F4A5B6C}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Project Hermes
DefaultDirName={localappdata}\ProjectHermes
DisableDirPage=yes
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={sys}\SndVol.exe
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=ProjectHermes-Setup
Compression=lzma2
SolidCompression=yes

[Files]
Source: "..\hermes_hotkey.ps1";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\hermes_launcher.vbs";  DestDir: "{app}"; Flags: ignoreversion
Source: "hermes_setup_helper.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Project Hermes"; Filename: "wscript.exe"; Parameters: """{app}\hermes_launcher.vbs"""; WorkingDir: "{app}"; IconFilename: "{sys}\SndVol.exe"; Comment: "Project Hermes voice dictation companion"
Name: "{userstartup}\Project Hermes"; Filename: "wscript.exe"; Parameters: """{app}\hermes_launcher.vbs"""; WorkingDir: "{app}"; IconFilename: "{sys}\SndVol.exe"; Comment: "Start Project Hermes at logon"

[Run]
; Stop any old daemon and merge the config (host/port preserved) before finishing.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\hermes_setup_helper.ps1"" -Mode postinstall -AppDir ""{app}"""; StatusMsg: "Applying Project Hermes configuration..."; Flags: runhidden waituntilterminated
; Optional launch now (Finish-page checkbox); the logon shortcut also starts it next sign-in.
Filename: "wscript.exe"; Parameters: """{app}\hermes_launcher.vbs"""; Description: "Start Project Hermes now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\hermes_setup_helper.ps1"" -Mode stop"; Flags: runhidden; RunOnceId: "StopHermesDaemon"
