; DagTech Miner - Windows Installer (Inno Setup 6)
; Build with: iscc dagtech-miner-setup.iss

#define AppName "DagTech Miner"
#define AppVersion "3.0.1"
#define AppPublisher "DagTech Ltd"
#define AppURL "https://dagtech.network"
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
DefaultDirName={%USERPROFILE}\.dagtech-miner
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Lock the install path — users editing it (e.g. removing the leading dot)
; previously broke the launcher. Path is fully validated and supported here only.
DisableDirPage=yes
AllowNoIcons=yes
OutputDir=..\..\dist
OutputBaseFilename=DagTech-Miner-v{#AppVersion}-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=120
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayName={#AppName}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=BlockDAG Network Mining Software
VersionInfoProductName={#AppName}
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

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
Source: "..\..\bin\windows\dagtech-miner.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\..\bin\windows\dagtech-gpu-miner.exe"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\..\bin\windows\dagtech-start.bat"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\..\bin\windows\dagtech-stop.bat"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\..\dashboard\index.html"; DestDir: "{app}\dashboard"; Flags: ignoreversion
Source: "..\..\dashboard\dashboard_server.py"; DestDir: "{app}\dashboard"; Flags: ignoreversion
Source: "..\..\assets\dagtech.ico"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "python-embed\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

[Dirs]
Name: "{app}\bin"
Name: "{app}\dashboard"
Name: "{app}\logs"
Name: "{app}\python"

[Icons]
; Desktop shortcut created via Code section to handle OneDrive Desktop gracefully
Name: "{group}\{#AppName}"; Filename: "{app}\bin\dagtech-start.bat"; WorkingDir: "{app}\bin"; IconFilename: "{app}\dagtech.ico"; Comment: "Start DagTech Miner"; Tasks: startmenuicon
Name: "{group}\Stop {#AppName}"; Filename: "{app}\bin\dagtech-stop.bat"; WorkingDir: "{app}\bin"; Comment: "Stop DagTech Miner"; Tasks: startmenuicon
Name: "{group}\Dashboard"; Filename: "http://localhost:8881"; Comment: "Open Mining Dashboard"; Tasks: startmenuicon
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"; Tasks: startmenuicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\bin\dagtech-start.bat"; WorkingDir: "{app}\bin"; Tasks: autostart

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; Check: NeedsAddPath(ExpandConstant('{app}\bin'))

[Run]
; Defender exclusion
Filename: "powershell.exe"; Parameters: "-Command ""Add-MpPreference -ExclusionPath '{app}'"""; StatusMsg: "Adding Windows Defender exclusion..."; Flags: runhidden; Tasks: defenderexclusion
; Start dashboard server (runs independently of miner)
Filename: "python"; Parameters: """{app}\dashboard\dashboard_server.py"" 8881 8880"; WorkingDir: "{app}\dashboard"; StatusMsg: "Starting dashboard server..."; Flags: nowait runhidden
; Open dashboard on finish
Filename: "http://localhost:8881"; Flags: nowait postinstall shellexec; Description: "Open mining dashboard"

[UninstallRun]
Filename: "taskkill"; Parameters: "/f /im dagtech-miner.exe"; Flags: runhidden
Filename: "taskkill"; Parameters: "/f /im dagtech-gpu-miner.exe"; Flags: runhidden
Filename: "powershell.exe"; Parameters: "-Command ""Remove-MpPreference -ExclusionPath '{app}'"""; Flags: runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: dirifempty; Name: "{app}"

[Code]
var
  ConfigPage: TInputQueryWizardPage;
  IsUpgrade: Boolean;
  ExistingWallet: String;
  ExistingWorker: String;
  ExistingPoolHost: String;
  ExistingPoolPort: String;
  ExistingThreads: String;

// Read a value from config.env
function ReadConfigValue(const FileName, Key: string): string;
var
  Lines: TArrayOfString;
  I: Integer;
  Line: string;
begin
  Result := '';
  if LoadStringsFromFile(FileName, Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Length(Line) > 0) and (Line[1] <> '#') then
      begin
        if Pos(Key + '=', Line) = 1 then
        begin
          Result := Copy(Line, Length(Key) + 2, Length(Line));
          exit;
        end;
      end;
    end;
  end;
end;

// Check if path needs adding
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

// Detect existing installation and read config
procedure DetectExistingInstall;
var
  ConfigFile: string;
begin
  ConfigFile := ExpandConstant('{%USERPROFILE}') + '\.dagtech-miner\config.env';
  IsUpgrade := FileExists(ConfigFile);
  if IsUpgrade then
  begin
    ExistingWallet := ReadConfigValue(ConfigFile, 'WALLET');
    ExistingWorker := ReadConfigValue(ConfigFile, 'WORKER_NAME');
    ExistingPoolHost := ReadConfigValue(ConfigFile, 'POOL_HOST');
    ExistingPoolPort := ReadConfigValue(ConfigFile, 'POOL_PORT');
    ExistingThreads := ReadConfigValue(ConfigFile, 'THREADS');
  end;
end;

// Create custom config wizard page
procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel2.Font.Size := 9;

  DetectExistingInstall;

  // Configuration page — appears before install
  ConfigPage := CreateInputQueryPage(wpSelectTasks,
    'Mining Configuration',
    'Configure your wallet, pool, and worker settings.',
    'Enter your BlockDAG wallet address and mining preferences. These can be changed later in the dashboard Settings tab.');

  ConfigPage.Add('Wallet Address (0x...):', False);
  ConfigPage.Add('Worker Name:', False);
  ConfigPage.Add('Pool Host:', False);
  ConfigPage.Add('Pool Port:', False);
  ConfigPage.Add('CPU Threads:', False);

  // Pre-fill with existing config or defaults
  if IsUpgrade then
  begin
    ConfigPage.Values[0] := ExistingWallet;
    ConfigPage.Values[1] := ExistingWorker;
    ConfigPage.Values[2] := ExistingPoolHost;
    ConfigPage.Values[3] := ExistingPoolPort;
    ConfigPage.Values[4] := ExistingThreads;
    ConfigPage.SubCaptionLabel.Caption := 'Existing configuration found. Review and update your settings below.';
  end
  else
  begin
    ConfigPage.Values[0] := '';
    ConfigPage.Values[1] := 'dagtech';
    ConfigPage.Values[2] := 'excalibur.dagtech.network';
    ConfigPage.Values[3] := '3335';
    ConfigPage.Values[4] := '4';
  end;
end;

// Check that a string contains only hex characters after the 0x prefix
function IsHexAddress(const Addr: string): Boolean;
var
  I: Integer;
  Ch: Char;
begin
  Result := False;
  if Length(Addr) <> 42 then exit;
  if Copy(Addr, 1, 2) <> '0x' then exit;
  for I := 3 to 42 do
  begin
    Ch := Addr[I];
    if not ((Ch >= '0') and (Ch <= '9')) and
       not ((Ch >= 'a') and (Ch <= 'f')) and
       not ((Ch >= 'A') and (Ch <= 'F')) then exit;
  end;
  Result := True;
end;

// Validate wallet on Next button
function NextButtonClick(CurPageID: Integer): Boolean;
var
  Wallet: string;
  WLen: Integer;
begin
  Result := True;
  if CurPageID = ConfigPage.ID then
  begin
    Wallet := Trim(ConfigPage.Values[0]);
    WLen := Length(Wallet);
    if WLen = 0 then
    begin
      MsgBox('Please enter your wallet address.', mbError, MB_OK);
      Result := False;
    end
    else if Copy(Wallet, 1, 2) <> '0x' then
    begin
      MsgBox('Wallet address must start with 0x', mbError, MB_OK);
      Result := False;
    end
    else if WLen < 42 then
    begin
      MsgBox('Wallet address too short (' + IntToStr(WLen) + ' chars, need 42). Check you copied the full address.', mbError, MB_OK);
      Result := False;
    end
    else if WLen > 42 then
    begin
      MsgBox('Wallet address too long (' + IntToStr(WLen) + ' chars, need 42). Remove extra characters.', mbError, MB_OK);
      Result := False;
    end
    else if not IsHexAddress(Wallet) then
    begin
      MsgBox('Wallet address contains non-hex characters. Address must be 0x followed by 40 hex digits (0-9, a-f).', mbError, MB_OK);
      Result := False;
    end
    else if LowerCase(Wallet) = '0x6387c32ccdd60bfba00ec70a67715dcd52e8083f' then
    begin
      MsgBox('That is the developer''s wallet address — rewards would go to the developer, not you.' + #13#10 + #13#10 +
             'Please enter YOUR own BlockDAG wallet address (the address you want to receive mining rewards).',
             mbError, MB_OK);
      Result := False;
    end;
  end;
end;

// Kill running processes before installing
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/f /im dagtech-miner.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill', '/f /im dagtech-gpu-miner.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill', '/f /im python.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1500);
  Result := '';
end;

// Write config.env after files are installed
procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigFile: string;
  Lines: TStringList;
begin
  if CurStep = ssPostInstall then
  begin
    // Create desktop shortcut with error handling (OneDrive may block)
    if IsTaskSelected('desktopicon') then
    begin
      try
        // Try standard desktop first
        CreateShellLink(
          ExpandConstant('{userdesktop}\{#AppName}.lnk'),
          '', ExpandConstant('{app}\bin\dagtech-start.bat'),
          '', ExpandConstant('{app}\bin'), '',
          0, SW_SHOWNORMAL);
      except
        // If OneDrive blocks, try the local desktop
        try
          CreateShellLink(
            ExpandConstant('{%USERPROFILE}\Desktop\{#AppName}.lnk'),
            '', ExpandConstant('{app}\bin\dagtech-start.bat'),
            '', ExpandConstant('{app}\bin'), '',
            0, SW_SHOWNORMAL);
        except
          // Just skip - Start Menu shortcut will work
        end;
      end;
    end;

    ConfigFile := ExpandConstant('{app}') + '\config.env';
    Lines := TStringList.Create;
    try
      Lines.Add('# DagTech Miner Configuration');
      Lines.Add('# Generated by DagTech Installer v' + '{#AppVersion}');
      Lines.Add('WALLET=' + Trim(ConfigPage.Values[0]));
      Lines.Add('POOL_HOST=' + Trim(ConfigPage.Values[2]));
      Lines.Add('POOL_PORT=' + Trim(ConfigPage.Values[3]));
      Lines.Add('MINING_MODE=cpu');
      Lines.Add('THREADS=' + Trim(ConfigPage.Values[4]));
      Lines.Add('WORKER_NAME=' + Trim(ConfigPage.Values[1]));
      Lines.Add('METRICS_PORT=8880');
      Lines.SaveToFile(ConfigFile);

      // Defense-in-depth: also write to legacy ~/.dagtech-miner/config.env so
      // any pre-existing launcher copies (from older installs or manual copies)
      // pick up the new config too. v3.1+ launchers find this via auto-discovery.
      try
        ForceDirectories(ExpandConstant('{%USERPROFILE}') + '\.dagtech-miner');
        Lines.SaveToFile(ExpandConstant('{%USERPROFILE}') + '\.dagtech-miner\config.env');
      except
        // best effort — install-dir copy is the authoritative one
      end;
    finally
      Lines.Free;
    end;
  end;
end;

// Check system requirements
function InitializeSetup: Boolean;
var
  WinVer: TWindowsVersion;
  OldUninstaller: string;
  ResultCode: Integer;
begin
  GetWindowsVersionEx(WinVer);
  if WinVer.Major < 10 then
  begin
    MsgBox('{#AppName} requires Windows 10 or newer.', mbError, MB_OK);
    Result := False;
    exit;
  end;

  // Check for old uninstaller and offer to remove
  OldUninstaller := ExpandConstant('{%USERPROFILE}') + '\.dagtech-miner\unins000.exe';
  if FileExists(OldUninstaller) then
  begin
    if MsgBox('An existing installation of {#AppName} was found.' + #13#10 + #13#10 +
              'Would you like to upgrade? Your configuration will be preserved.' + #13#10 + #13#10 +
              'Click Yes to upgrade, or No to cancel.',
              mbConfirmation, MB_YESNO) = IDNO then
    begin
      Result := False;
      exit;
    end;
    // Run old uninstaller silently but keep config
    Exec(OldUninstaller, '/VERYSILENT /SUPPRESSMSGBOXES', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(1000);
  end;

  Result := True;
end;

// Cleanup on uninstall - remove from PATH
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path, AppPath: string;
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
