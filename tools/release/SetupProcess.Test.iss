#ifndef OutputDir
  #error Build this check with tools\scripts\Test-SetupProcess.ps1
#endif

[Setup]
AppId={{5A0C6E44-3D75-4C8B-A3F2-9E1B7C2D4F10}
AppName=Performance Tuning Utility setup process check
AppVersion=0
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=SetupProcessCheck

[Code]
#include "SetupProcess.iss"

var
  Report: TArrayOfString;

procedure Note(const Text: String);
begin
  SetArrayLength(Report, GetArrayLength(Report) + 1);
  Report[GetArrayLength(Report) - 1] := Text;
end;

function FolderRegLoad(Path: String; var Key: THandle; Access, Options, Reserved: DWORD): Longint; external 'RegLoadAppKeyW@advapi32.dll stdcall';
function FolderRegOpen(Key: THandle; Sub: String; Options, Access: DWORD; var ResultKey: THandle): Longint; external 'RegOpenKeyExW@advapi32.dll stdcall';
function FolderRegOverride(Key, NewKey: THandle): Longint; external 'RegOverridePredefKey@advapi32.dll stdcall';
function FolderRegClose(Key: THandle): Longint; external 'RegCloseKey@advapi32.dll stdcall';

function InitializeSetup(): Boolean;
var
  Work, Shell, Dump, Block: String;
  Code: DWORD;
  Started: DWORD;
  Ran: Boolean;
  ExecCode: Integer;
  FixturePath, FixtureSid: String;
  FixtureKey, UserKey: THandle;
  Names: TArrayOfString;
  Index: Integer;
begin
  Work := ExpandConstant('{param:work}');
  if ExpandConstant('{param:migration}') = '1' then
  begin
    Shell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    Started := GetTickCount;
    Ran := RunBounded(Shell, '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Work + '\Invoke-FixtureResume.ps1" -Work "' + Work + '"', Work + '\setup-temp', 12000, Code);
    Note('migration ran=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(Code) + ' ms=' + IntToStr(GetTickCount - Started));
    SaveStringsToFile(Work + '\migration-report.txt', Report, False);
    Result := False;
    exit;
  end;
  FixturePath := ExpandConstant('{param:folderfixture}');
  if FixturePath <> '' then
  begin
    FixtureSid := ExpandConstant('{param:fixturesid}');
    if FolderRegLoad(FixturePath, FixtureKey, $F003F, 0, 0) <> 0 then RaiseException('Fixture hive failed');
    if FolderRegOpen(FixtureKey, FixtureSid, 0, $F003F, UserKey) <> 0 then RaiseException('Fixture SID failed');
    if FolderRegOverride(HKCU, UserKey) <> 0 then RaiseException('Fixture override failed');
    try
      try
        Block := SetupEnvironment(ExpandConstant('{param:foldertemp|' + Work + '\setup-temp}'));
        SaveStringToFile(Work + '\folder-block.txt', Block, False);
        Note('folder refused=0');
        if ExpandConstant('{param:folderchild}') = '1' then
        begin
          Dump := '-NoProfile -NonInteractive -Command "Get-ChildItem Env: | ForEach-Object { $_.Name + ''='' + $_.Value } | Set-Content -LiteralPath ''' + Work + '\folder-child.txt''; Set-Content -LiteralPath ''' + Work + '\folder-bits.txt'' ([IntPtr]::Size*8); exit 7"';
          Ran := RunBounded(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Dump, Work + '\setup-temp', 30000, Code);
          Note('folder child=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(Code));
        end;
      except
        Note('folder refused=1 ' + GetExceptionMessage);
      end;
      SaveStringsToFile(Work + '\folder-report.txt', Report, False);
    finally
      FolderRegOverride(HKCU, 0);
      FolderRegClose(UserKey);
      FolderRegClose(FixtureKey);
    end;
    Result := False;
    exit;
  end;
  Shell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  SetEnvironmentVariable('windir', Work + '\marker');
  SetEnvironmentVariable('SystemRoot', Work + '\marker');
  SetEnvironmentVariable('PATH', Work + '\marker;' + GetEnv('PATH'));
  SetEnvironmentVariable('DOTNET_gcServer', '1');
  SetEnvironmentVariable('COMPlus_gcServer', '1');
  SetEnvironmentVariable('TEMP', Work + '\marker\temp');
  SetEnvironmentVariable('TMP', Work + '\marker\temp');
  SetEnvironmentVariable('USERPROFILE', Work + '\marker\profile');
  SetEnvironmentVariable('LOCALAPPDATA', Work + '\marker\local');
  SetEnvironmentVariable('APPDATA', Work + '\marker\roaming');
  SetEnvironmentVariable('HOMEDRIVE', Work + '\marker');
  SetEnvironmentVariable('HOMEPATH', Work + '\marker');
  SetEnvironmentVariable('PUBLIC', Work + '\marker');
  SetEnvironmentVariable('USERDOMAIN', 'marker');

  Block := SetupEnvironment(Work + '\setup-temp');
  SaveStringToFile(Work + '\block.txt', Block, False);
  Dump := '-NoProfile -NonInteractive -Command "Get-ChildItem Env: | ForEach-Object { $_.Name + ''='' + $_.Value } | Set-Content -LiteralPath ''' + Work + '\env.txt''; Set-Content -LiteralPath ''' + Work + '\bits.txt'' ([IntPtr]::Size*8); exit 7"';
  Started := GetTickCount;
  Ran := RunBounded(Shell, Dump, Work + '\setup-temp', 60000, Code);
  Note('A ran=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(Code) + ' ms=' + IntToStr(GetTickCount - Started));

  Started := GetTickCount;
  Ran := RunBounded(Shell, '-NoProfile -NonInteractive -Command "$p=Start-Process -FilePath ''' + ExpandConstant('{sys}') + '\PING.EXE'' -ArgumentList ''-n'',''60'',''127.0.0.1'' -WindowStyle Hidden -PassThru; Set-Content -LiteralPath ''' + Work + '\child.txt'' $p.Id; Set-Content -LiteralPath ''' + Work + '\started.txt'' x; Start-Sleep -Seconds 60; Set-Content -LiteralPath ''' + Work + '\finished.txt'' x"', Work + '\setup-temp', 3000, Code);
  Note('B ran=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(Code) + ' ms=' + IntToStr(GetTickCount - Started));
  Sleep(2000);
  Note('B finished=' + IntToStr(Ord(FileExists(Work + '\finished.txt'))));

  Ran := RunBounded(Work + '\missing\nothing.exe', '', Work, 3000, Code);
  Note('C ran=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(Code));

  SetEnvironmentVariable('windir', ExpandConstant('{win}'));
  SetEnvironmentVariable('SystemRoot', ExpandConstant('{win}'));
  Started := GetTickCount;
  Ran := Exec(Shell, '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 12"', '', SW_HIDE, ewWaitUntilTerminated, ExecCode);
  Note('D ran=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(ExecCode) + ' ms=' + IntToStr(GetTickCount - Started));

  SetEnvironmentVariable('DOTNET_GCConfigLogEnabled', '1');
  SetEnvironmentVariable('DOTNET_GCConfigLogFile', Work + '\scratch\gc.log');
  SetEnvironmentVariable('COMPlus_JitTimeLogFile', Work + '\scratch\jit.log');
  SetEnvironmentVariable('complus_x', '1');
  SetEnvironmentVariable('DOTNET_ROO_INDUSTRIES_UNKNOWN_KNOB', '1');
  SetEnvironmentVariable('CORECLR_ENABLE_PROFILING', '1');
  SetEnvironmentVariable('COR_PROFILER', 'a b & c ^ d % e');
  SetEnvironmentVariable('COREHOST_TRACE', '1');
  SetEnvironmentVariable('ROO_INDUSTRIES_UNRELATED_MARKER', 'kept');
  ClearCodeLoading;
  Names := PrefixedNames;
  for Index := 0 to GetArrayLength(Names) - 1 do
    Note('E ' + Names[Index] + '=' + GetEnv(Names[Index]));
  Note('F unrelated=' + GetEnv('ROO_INDUSTRIES_UNRELATED_MARKER'));

  Ran := RunBounded(Shell, '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Work + '\Invoke-GovernorSetup.ps1" -Action Suspend -AppRoot "' + Work + '\governor-app" -StatePath "' + Work + '\governor-state.json" -LogPath "' + Work + '\governor.log"', Work + '\setup-temp', 60000, Code);
  Note('G ran=' + IntToStr(Ord(Ran)) + ' exit=' + IntToStr(Code));

  SaveStringsToFile(Work + '\report.txt', Report, False);
  Result := False;
end;
