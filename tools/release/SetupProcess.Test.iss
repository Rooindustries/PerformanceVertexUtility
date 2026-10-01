#ifndef OutputDir
  #error Build this check with tools\scripts\Test-SetupProcess.ps1
#endif

[Setup]
AppId={{5A0C6E44-3D75-4C8B-A3F2-9E1B7C2D4F10}
AppName=Roo Industries setup process check
AppVersion=0
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=SetupProcessCheck

[Code]
#include "SetupProcess.iss"

function SetEnvironmentVariable(Name: String; Value: String): Boolean; external 'SetEnvironmentVariableW@kernel32.dll stdcall';

var
  Report: TArrayOfString;

procedure Note(const Text: String);
begin
  SetArrayLength(Report, GetArrayLength(Report) + 1);
  Report[GetArrayLength(Report) - 1] := Text;
end;

function InitializeSetup(): Boolean;
var
  Work, Shell, Dump: String;
  Code: DWORD;
  Started: DWORD;
  Ran: Boolean;
  ExecCode: Integer;
begin
  Work := ExpandConstant('{param:work}');
  Shell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  SetEnvironmentVariable('windir', Work + '\marker');
  SetEnvironmentVariable('SystemRoot', Work + '\marker');
  SetEnvironmentVariable('PATH', Work + '\marker;' + GetEnv('PATH'));
  SetEnvironmentVariable('DOTNET_gcServer', '1');
  SetEnvironmentVariable('COMPlus_gcServer', '1');
  SetEnvironmentVariable('TEMP', Work + '\marker\temp');
  SetEnvironmentVariable('TMP', Work + '\marker\temp');

  Dump := '-NoProfile -NonInteractive -Command "Get-ChildItem Env: | ForEach-Object { $_.Name + ''='' + $_.Value } | Set-Content -LiteralPath ''' + Work + '\env.txt''; exit 7"';
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

  SaveStringsToFile(Work + '\report.txt', Report, False);
  Result := False;
end;
