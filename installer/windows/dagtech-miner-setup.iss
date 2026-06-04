; DagTech Miner - Windows Installer (Inno Setup)
; Build with: iscc dagtech-miner-setup.iss
; Download Inno Setup: https://jrsoftware.org/isinfo.php

#define AppName "DagTech Miner"
#define AppVersion "3.0.0"
#define AppPublisher "DagTech Ltd"
#define AppURL "https://dagtech.network"
#define AppExeName "dagtech-miner.exe"
#define MinerURL "https://miner.dagtech.network"

[Setup]
AppId={{A7E3D4F1-B2C8-4D5E-9F1A-3C6B8D2E7F4A}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} v{#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#MinerURL}
AppUpdatesURL={#MinerURL}
DefaultDirName={userappdata}\DagTech Miner
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; LicenseFile=..\..\LICENSE
OutputDir=..\..\dist
OutputBaseFilename=DagTech-Miner-v{#AppVersion}-Setup
; SetupIconFile=..\..\assets\dagtech.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=120
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\dagtech.ico
UninstallDisplayName={#AppName}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=BlockDAG Network Mining Software
VersionInfoProductName={#AppName}
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; WizardImageFile=wizard-large.bmp
; WizardSmallImageFile=wizard-small.bmp

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=Welcome to {#AppName}
WelcomeLabel2=This will install {#AppName} v{#AppVersion} on your computer.%n%nThe miner connects to the BlockDAG Network and earns BDAG coins using your CPU and optional NVIDIA GPU.%n%nVisit {#MinerURL} for documentation and guides.

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startmenuicon"; Description: "Create a Start Menu entry"; GroupDescription: "Shortcuts:"
Name: "autostart"; Description: "Start mining automatically on Windows login"; GroupDescription: "Options:"; Flags: unchecked
Name: "defenderexclusion"; Description: "Add Windows Defender exclusion (recommended)"; GroupDescription: "Security:"

[Files]
; Core miner binaries
Source: "..\..\bin\windows\dagtech-miner.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\..\bin\windows\dagtech-gpu-miner.exe"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\..\bin\windows\dagtech-start.bat"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\..\bin\windows\dagtech-stop.bat"; DestDir: "{app}\bin"; Flags: ignoreversion

; Dashboard
Source: "..\..\dashboard\index.html"; DestDir: "{app}\dashboard"; Flags: ignoreversion
Source: "..\..\dashboard\dashboard_server.py"; DestDir: "{app}\dashboard"; Flags: ignoreversion

; Icon
Source: "..\..\assets\dagtech.ico"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; Python embedded (portable, no system install needed)
Source: "python-embed\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

[Dirs]
Name: "{app}\bin"
Name: "{app}\dashboard"
Name: "{app}\logs"
Name: "{app}\python"

[Icons]
; Desktop
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\bin\dagtech-start.bat"; WorkingDir: "{app}\bin"; IconFilename: "{app}\dagtech.ico"; Comment: "Start DagTech Miner"; Tasks: desktopicon
; Start Menu
Name: "{group}\{#AppName}"; Filename: "{app}\bin\dagtech-start.bat"; WorkingDir: "{app}\bin"; IconFilename: "{app}\dagtech.ico"; Comment: "Start DagTech Miner"; Tasks: startmenuicon
Name: "{group}\Stop {#AppName}"; Filename: "{app}\bin\dagtech-stop.bat"; WorkingDir: "{app}\bin"; IconFilename: "{app}\dagtech.ico"; Comment: "Stop DagTech Miner"; Tasks: startmenuicon
Name: "{group}\Dashboard"; Filename: "http://localhost:8881"; IconFilename: "{app}\dagtech.ico"; Comment: "Open Mining Dashboard"; Tasks: startmenuicon
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"; Tasks: startmenuicon

; Auto-start on login
Name: "{userstartup}\{#AppName}"; Filename: "{app}\bin\dagtech-start.bat"; WorkingDir: "{app}\bin"; IconFilename: "{app}\dagtech.ico"; Tasks: autostart

[Registry]
; Add to user PATH
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; Check: NeedsAddPath(ExpandConstant('{app}\bin'))

[Run]
; Add Defender exclusion
Filename: "powershell.exe"; Parameters: "-Command ""Add-MpPreference -ExclusionPath '{app}'"""; StatusMsg: "Adding Windows Defender exclusion..."; Flags: runhidden; Tasks: defenderexclusion
; Configuration wizard
Filename: "{app}\bin\dagtech-config.bat"; StatusMsg: "Opening configuration wizard..."; Flags: nowait postinstall skipifsilent; Description: "Configure wallet and pool settings"
; Open dashboard
Filename: "http://localhost:8881"; Flags: nowait postinstall skipifsilent shellexec; Description: "Open mining dashboard"
; Start mining
Filename: "{app}\bin\dagtech-start.bat"; Flags: nowait postinstall skipifsilent; Description: "Start mining now"

[UninstallRun]
; Stop miner before uninstall
Filename: "{app}\bin\dagtech-stop.bat"; Flags: runhidden
; Remove Defender exclusion
Filename: "powershell.exe"; Parameters: "-Command ""Remove-MpPreference -ExclusionPath '{app}'"""; Flags: runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: dirifempty; Name: "{app}"

[Code]
// Check if path already contains our directory
function NeedsAddPath(Param: string): boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Param + ';', ';' + OrigPath + ';') = 0;
end;

// Custom welcome page info
procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel2.Font.Size := 9;
end;

// Check system requirements
function InitializeSetup: Boolean;
var
  WinVer: TWindowsVersion;
begin
  GetWindowsVersionEx(WinVer);
  if WinVer.Major < 10 then
  begin
    MsgBox('DagTech Miner requires Windows 10 or newer.', mbError, MB_OK);
    Result := False;
    exit;
  end;
  Result := True;
end;

// Cleanup on uninstall — remove from PATH
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path: string;
  AppPath: string;
  P: Integer;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    AppPath := ExpandConstant('{app}\bin');
    if RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then
    begin
      P := Pos(';' + AppPath, Path);
      if P > 0 then
      begin
        Delete(Path, P, Length(';' + AppPath));
        RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path);
      end;
    end;
  end;
end;
