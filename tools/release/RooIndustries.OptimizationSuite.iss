#ifndef AppVersion
  #error Build the installer with tools\scripts\Build-Release.ps1
#endif

#define AppName "Roo Industries Optimization Suite"
#define AppExe "RooIndustries.OptimizationSuite.App.exe"

[Setup]
AppId={{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Roo Industries
AppCopyright=Roo Industries
VersionInfoVersion={#AppNumericVersion}
VersionInfoProductVersion={#AppNumericVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup
DefaultDirName={autopf}\Roo Industries\Optimization Suite
DefaultGroupName=Roo Industries
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile={#SourceDir}\assets\brand\roo-industries\favicon.ico
UninstallDisplayIcon={app}\app\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[InstallDelete]
Type: filesandordirs; Name: "{app}\app"
Type: filesandordirs; Name: "{app}\backend\bin\optimizer"
Type: files; Name: "{app}\backend\bin\RooIndustriesProcessGovernor.exe"
Type: filesandordirs; Name: "{app}\backend\scripts"
Type: filesandordirs; Name: "{app}\backend\catalogs"
Type: filesandordirs; Name: "{app}\backend\native"

[Files]
Source: "{#SourceDir}\backend\scripts\Invoke-GovernorSetup.ps1"; Flags: dontcopy
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\app\{#AppExe}"; WorkingDir: "{app}\app"
Name: "{group}\Beta tester guide"; Filename: "{app}\README-BETA.txt"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\app\{#AppExe}"; WorkingDir: "{app}\app"; Tasks: desktopicon

[Run]
Filename: "{app}\README-BETA.txt"; Description: "Read the beta tester guide"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\app\{#AppExe}"; Description: "Open {#AppName}"; Flags: postinstall shellexec skipifsilent nowait unchecked

[UninstallDelete]
Type: files; Name: "{app}\backend\bin\RooIndustriesProcessGovernor.exe"
Type: dirifempty; Name: "{app}\backend\bin"
Type: dirifempty; Name: "{app}\backend"
Type: dirifempty; Name: "{app}"
Type: dirifempty; Name: "{autopf}\Roo Industries"

[Code]
var
  GovernorSuspended: Boolean;
  GovernorResumed: Boolean;

function RunGovernorSetup(const Script, Action: String): Boolean;
var
  Code: Integer;
  LogPath: String;
  Output: AnsiString;
begin
  LogPath := ExpandConstant('{tmp}\governor-setup.log');
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Script + '" -Action ' + Action +
    ' -AppRoot "' + ExpandConstant('{app}') + '" -StatePath "' + ExpandConstant('{tmp}\governor-suspended.json') + '" -LogPath "' + LogPath + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  if LoadStringFromFile(LogPath, Output) then Log(String(Output));
  Log('Roo Industries Governor ' + Action + ' finished with exit code ' + IntToStr(Code));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  ExtractTemporaryFile('Invoke-GovernorSetup.ps1');
  if not RunGovernorSetup(ExpandConstant('{tmp}\Invoke-GovernorSetup.ps1'), 'Suspend') then
  begin
    RunGovernorSetup(ExpandConstant('{tmp}\Invoke-GovernorSetup.ps1'), 'Resume');
    Result := 'Setup could not stop the Roo Industries Governor safely, so no files were changed. Restart Windows and run setup again.';
  end
  else
    GovernorSuspended := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and GovernorSuspended then
  begin
    GovernorResumed := True;
    if not RunGovernorSetup(ExpandConstant('{tmp}\Invoke-GovernorSetup.ps1'), 'Resume') then
      Log('The Roo Industries Governor could not be started again. Open the app and press Start governor.');
  end;
end;

procedure DeinitializeSetup();
begin
  if GovernorSuspended and not GovernorResumed then
    RunGovernorSetup(ExpandConstant('{tmp}\Invoke-GovernorSetup.ps1'), 'Resume');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
  LogPath: String;
  Output: AnsiString;
begin
  if CurUninstallStep = usUninstall then
  begin
    LogPath := ExpandConstant('{tmp}\governor-uninstall.log');
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\backend\scripts\Invoke-GovernorSetup.ps1') + '" -Action Remove -AppRoot "' +
      ExpandConstant('{app}') + '" -LogPath "' + LogPath + '"', '', SW_HIDE, ewWaitUntilTerminated, Code);
    if LoadStringFromFile(LogPath, Output) then Log(String(Output));
    Log('Roo Industries Governor removal finished with exit code ' + IntToStr(Code));
    if Code <> 0 then
      SuppressibleMsgBox('The Roo Industries Governor could not be removed completely. Restart Windows, then check Task Scheduler for tasks named RooIndustriesOptimizationSuite.ProcessRules and delete them.', mbError, MB_OK, IDOK);
  end;
end;
