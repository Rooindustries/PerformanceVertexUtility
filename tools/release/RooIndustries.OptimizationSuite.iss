#ifndef AppVersion
  #error Build the installer with tools\scripts\Build-Release.ps1
#endif
#ifndef GovernorSetupHash
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
Type: filesandordirs; Name: "{app}\setup"
Type: files; Name: "{app}\backend\bin\RooIndustriesProcessGovernor.exe"
Type: dirifempty; Name: "{app}\backend\bin"
Type: dirifempty; Name: "{app}\backend"
Type: dirifempty; Name: "{app}"
Type: dirifempty; Name: "{autopf}\Roo Industries"

[Code]
var
  GovernorSuspended: Boolean;
  GovernorResumed: Boolean;
  SetupFolder: String;

function GetCurrentProcessId: Cardinal; external 'GetCurrentProcessId@kernel32.dll stdcall';
function SetEnvironmentVariable(Name: String; Value: String): Boolean; external 'SetEnvironmentVariableW@kernel32.dll stdcall';

procedure ClearCodeLoading;
var
  Names: TArrayOfString;
  Index: Integer;
begin
  Names := ['COR_ENABLE_PROFILING', 'COR_PROFILER', 'COR_PROFILER_PATH', 'COR_PROFILER_PATH_32', 'COR_PROFILER_PATH_64', 'CORECLR_ENABLE_PROFILING',
    'CORECLR_PROFILER', 'CORECLR_PROFILER_PATH', 'CORECLR_PROFILER_PATH_32', 'CORECLR_PROFILER_PATH_64', 'CORECLR_PROFILER_PATH_ARM64',
    'DOTNET_STARTUP_HOOKS', 'DOTNET_ADDITIONAL_DEPS', 'DOTNET_SHARED_STORE'];
  for Index := 0 to GetArrayLength(Names) - 1 do
    SetEnvironmentVariable(Names[Index], '');
  SetEnvironmentVariable('PSModulePath', ExpandConstant('{commonpf64}\WindowsPowerShell\Modules;{sys}\WindowsPowerShell\v1.0\Modules'));
end;

function InitializeSetup(): Boolean;
begin
  ClearCodeLoading;
  Result := True;
end;

function InitializeUninstall(): Boolean;
begin
  ClearCodeLoading;
  Result := True;
end;

function PrepareSetupFolder: Boolean;
var
  Script: String;
begin
  SetupFolder := ExpandConstant('{app}\setup');
  if DirExists(SetupFolder) then
    DelTree(SetupFolder, True, True, True);
  Result := ForceDirectories(SetupFolder);
  if not Result then
    exit;
  ExtractTemporaryFile('Invoke-GovernorSetup.ps1');
  Script := SetupFolder + '\Invoke-GovernorSetup.ps1';
  Result := FileCopy(ExpandConstant('{tmp}\Invoke-GovernorSetup.ps1'), Script, False) and (CompareText(GetSHA256OfFile(Script), '{#GovernorSetupHash}') = 0);
  if not Result then
    Log('The copied Roo Industries Governor setup script did not match the installer.');
end;

function RunGovernorSetup(const Action: String): Boolean;
var
  Code: Integer;
  LogPath: String;
  Output: AnsiString;
begin
  LogPath := SetupFolder + '\governor-setup.log';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + SetupFolder + '\Invoke-GovernorSetup.ps1" -Action ' + Action +
    ' -AppRoot "' + ExpandConstant('{app}') + '" -StatePath "' + SetupFolder + '\governor-suspended.json" -LogPath "' + LogPath + '" -SetupProcessId ' + IntToStr(GetCurrentProcessId()),
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  if LoadStringFromFile(LogPath, Output) then Log(String(Output));
  Log('Roo Industries Governor ' + Action + ' finished with exit code ' + IntToStr(Code));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not PrepareSetupFolder then
  begin
    Result := 'Setup could not prepare its governor files safely, so no files were changed. Run setup again.';
    exit;
  end;
  if not RunGovernorSetup('Suspend') then
  begin
    RunGovernorSetup('Resume');
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
    if not RunGovernorSetup('Resume') then
      Log('The Roo Industries Governor could not be started again. Open the app and press Start governor.');
  end;
end;

procedure DeinitializeSetup();
begin
  if GovernorSuspended and not GovernorResumed then
    RunGovernorSetup('Resume');
  if (SetupFolder <> '') and DirExists(SetupFolder) then
    DelTree(SetupFolder, True, True, True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
  Folder: String;
  LogPath: String;
  Output: AnsiString;
begin
  if CurUninstallStep = usUninstall then
  begin
    Folder := ExpandConstant('{app}\setup');
    ForceDirectories(Folder);
    LogPath := Folder + '\governor-uninstall.log';
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\backend\scripts\Invoke-GovernorSetup.ps1') + '" -Action Remove -AppRoot "' +
      ExpandConstant('{app}') + '" -LogPath "' + LogPath + '"', '', SW_HIDE, ewWaitUntilTerminated, Code);
    if LoadStringFromFile(LogPath, Output) then Log(String(Output));
    DelTree(Folder, True, True, True);
    Log('Roo Industries Governor removal finished with exit code ' + IntToStr(Code));
    if Code <> 0 then
      SuppressibleMsgBox('The Roo Industries Governor could not be removed completely. Restart Windows, then check Task Scheduler for tasks named RooIndustriesOptimizationSuite.ProcessRules and delete them.', mbError, MB_OK, IDOK);
  end;
end;
