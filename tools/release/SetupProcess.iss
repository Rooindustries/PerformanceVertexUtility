const
  CREATE_UNICODE_ENVIRONMENT = $00000400;
  CREATE_NO_WINDOW = $08000000;
  STARTF_USESHOWWINDOW = $00000001;
  WAIT_TIMEOUT = 258;
  TimedOutExitCode = 258;

type
  TStartupInfo = record
    cb: DWORD;
    lpReserved: DWORD;
    lpDesktop: DWORD;
    lpTitle: DWORD;
    dwX: DWORD;
    dwY: DWORD;
    dwXSize: DWORD;
    dwYSize: DWORD;
    dwXCountChars: DWORD;
    dwYCountChars: DWORD;
    dwFillAttribute: DWORD;
    dwFlags: DWORD;
    wShowWindow: Word;
    cbReserved2: Word;
    lpReserved2: DWORD;
    hStdInput: THandle;
    hStdOutput: THandle;
    hStdError: THandle;
  end;
  TProcessInformation = record
    hProcess: THandle;
    hThread: THandle;
    dwProcessId: DWORD;
    dwThreadId: DWORD;
  end;
  TWindowMessage = record
    hwnd: HWND;
    message: DWORD;
    wParam: Longint;
    lParam: Longint;
    time: DWORD;
    x: Longint;
    y: Longint;
  end;

function CreateProcessW(ApplicationName: String; CommandLine: String; ProcessAttributes: DWORD; ThreadAttributes: DWORD; InheritHandles: BOOL; CreationFlags: DWORD; Environment: String; CurrentDirectory: String; var StartupInfo: TStartupInfo; var ProcessInformation: TProcessInformation): BOOL; external 'CreateProcessW@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: DWORD): DWORD; external 'WaitForSingleObject@kernel32.dll stdcall';
function GetExitCodeProcess(Handle: THandle; var ExitCode: DWORD): BOOL; external 'GetExitCodeProcess@kernel32.dll stdcall';
function TerminateProcess(Handle: THandle; ExitCode: DWORD): BOOL; external 'TerminateProcess@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): BOOL; external 'CloseHandle@kernel32.dll stdcall';
function GetTickCount: DWORD; external 'GetTickCount@kernel32.dll stdcall';
function PeekMessage(var Message: TWindowMessage; Window: HWND; FilterMin: DWORD; FilterMax: DWORD; Remove: DWORD): BOOL; external 'PeekMessageW@user32.dll stdcall';
function TranslateMessage(var Message: TWindowMessage): BOOL; external 'TranslateMessage@user32.dll stdcall';
function DispatchMessage(var Message: TWindowMessage): Longint; external 'DispatchMessageW@user32.dll stdcall';

procedure PumpMessages;
var
  Message: TWindowMessage;
begin
  while PeekMessage(Message, 0, 0, 0, 1) do
  begin
    TranslateMessage(Message);
    DispatchMessage(Message);
  end;
end;

function EnvironmentEntry(const Name, Value: String): String;
begin
  Result := Name + '=' + Value + #0;
end;

function SetupEnvironment(const TempFolder: String): String;
var
  Profile: String;
begin
  Profile := ExtractFileDir(ExtractFileDir(ExpandConstant('{userappdata}')));
  Result :=
    EnvironmentEntry('SystemRoot', ExpandConstant('{win}')) +
    EnvironmentEntry('windir', ExpandConstant('{win}')) +
    EnvironmentEntry('SystemDrive', ExtractFileDrive(ExpandConstant('{win}'))) +
    EnvironmentEntry('ComSpec', ExpandConstant('{sys}\cmd.exe')) +
    EnvironmentEntry('PATH', ExpandConstant('{sys};{win};{sys}\Wbem;{sys}\WindowsPowerShell\v1.0')) +
    EnvironmentEntry('PATHEXT', '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC') +
    EnvironmentEntry('PSModulePath', ExpandConstant('{commonpf64}\WindowsPowerShell\Modules;{sys}\WindowsPowerShell\v1.0\Modules')) +
    EnvironmentEntry('TEMP', TempFolder) +
    EnvironmentEntry('TMP', TempFolder) +
    EnvironmentEntry('ProgramFiles', ExpandConstant('{commonpf64}')) +
    EnvironmentEntry('ProgramW6432', ExpandConstant('{commonpf64}')) +
    EnvironmentEntry('ProgramFiles(x86)', ExpandConstant('{commonpf32}')) +
    EnvironmentEntry('CommonProgramFiles', ExpandConstant('{commoncf64}')) +
    EnvironmentEntry('CommonProgramW6432', ExpandConstant('{commoncf64}')) +
    EnvironmentEntry('CommonProgramFiles(x86)', ExpandConstant('{commoncf32}')) +
    EnvironmentEntry('ProgramData', ExpandConstant('{commonappdata}')) +
    EnvironmentEntry('ALLUSERSPROFILE', ExpandConstant('{commonappdata}')) +
    EnvironmentEntry('USERPROFILE', Profile) +
    EnvironmentEntry('APPDATA', ExpandConstant('{userappdata}')) +
    EnvironmentEntry('LOCALAPPDATA', ExpandConstant('{localappdata}')) +
    EnvironmentEntry('USERNAME', GetUserNameString) +
    EnvironmentEntry('COMPUTERNAME', GetComputerNameString) +
    EnvironmentEntry('OS', 'Windows_NT');
  Result := Result + #0;
end;

function RunProcess(const FileName, Parameters, TempFolder: String; const TimeoutMilliseconds: DWORD; const StopChildren: Boolean; var ExitCode: DWORD): Boolean; forward;

procedure StopProcessTree(const ProcessId: DWORD; const TempFolder: String);
var
  Ignored: DWORD;
begin
  RunProcess(ExpandConstant('{sys}\taskkill.exe'), '/PID ' + IntToStr(ProcessId) + ' /T /F', TempFolder, 15000, False, Ignored);
end;

function RunProcess(const FileName, Parameters, TempFolder: String; const TimeoutMilliseconds: DWORD; const StopChildren: Boolean; var ExitCode: DWORD): Boolean;
var
  Startup: TStartupInfo;
  Process: TProcessInformation;
  Command: String;
  Started: DWORD;
begin
  Result := False;
  ExitCode := 1;
  Command := '"' + FileName + '" ' + Parameters;
  Startup.cb := 68;
  Startup.lpReserved := 0;
  Startup.lpDesktop := 0;
  Startup.lpTitle := 0;
  Startup.dwX := 0;
  Startup.dwY := 0;
  Startup.dwXSize := 0;
  Startup.dwYSize := 0;
  Startup.dwXCountChars := 0;
  Startup.dwYCountChars := 0;
  Startup.dwFillAttribute := 0;
  Startup.dwFlags := STARTF_USESHOWWINDOW;
  Startup.wShowWindow := SW_HIDE;
  Startup.cbReserved2 := 0;
  Startup.lpReserved2 := 0;
  Startup.hStdInput := 0;
  Startup.hStdOutput := 0;
  Startup.hStdError := 0;
  Process.hProcess := 0;
  Process.hThread := 0;
  Process.dwProcessId := 0;
  Process.dwThreadId := 0;
  if not CreateProcessW(FileName, Command, 0, 0, False, CREATE_UNICODE_ENVIRONMENT or CREATE_NO_WINDOW, SetupEnvironment(TempFolder), ExpandConstant('{sys}'), Startup, Process) then
    exit;
  CloseHandle(Process.hThread);
  try
    Started := GetTickCount;
    while WaitForSingleObject(Process.hProcess, 200) = WAIT_TIMEOUT do
    begin
      PumpMessages;
      if GetTickCount - Started > TimeoutMilliseconds then
      begin
        if StopChildren then
          StopProcessTree(Process.dwProcessId, TempFolder);
        TerminateProcess(Process.hProcess, TimedOutExitCode);
        WaitForSingleObject(Process.hProcess, 5000);
        ExitCode := TimedOutExitCode;
        Log('Stopped ' + ExtractFileName(FileName) + ' after ' + IntToStr(TimeoutMilliseconds div 1000) + ' seconds.');
        exit;
      end;
    end;
    Result := GetExitCodeProcess(Process.hProcess, ExitCode);
  finally
    CloseHandle(Process.hProcess);
  end;
end;

function RunBounded(const FileName, Parameters, TempFolder: String; const TimeoutMilliseconds: DWORD; var ExitCode: DWORD): Boolean;
begin
  Result := RunProcess(FileName, Parameters, TempFolder, TimeoutMilliseconds, True, ExitCode);
end;

function SetEnvironmentVariable(Name: String; Value: String): Boolean; external 'SetEnvironmentVariableW@kernel32.dll stdcall';
function RemoveEnvironmentVariable(Name: String; Value: Cardinal): Boolean; external 'SetEnvironmentVariableW@kernel32.dll stdcall';
function GetEnvironmentStringsW: Cardinal; external 'GetEnvironmentStringsW@kernel32.dll stdcall';
function FreeEnvironmentStringsW(Block: Cardinal): Boolean; external 'FreeEnvironmentStringsW@kernel32.dll stdcall';
function lstrlenW(Text: Cardinal): Integer; external 'lstrlenW@kernel32.dll stdcall';
function lstrcpynW(Target: String; Text: Cardinal; Count: Integer): Cardinal; external 'lstrcpynW@kernel32.dll stdcall';

function HasClearedPrefix(const Name: String): Boolean;
var
  Prefixes: TArrayOfString;
  Index: Integer;
begin
  Prefixes := ['DOTNET_', 'COMPlus_', 'CORECLR_', 'COR_', 'COREHOST_'];
  Result := False;
  for Index := 0 to GetArrayLength(Prefixes) - 1 do
    if CompareText(Copy(Name, 1, Length(Prefixes[Index])), Prefixes[Index]) = 0 then
      Result := True;
end;

function PrefixedNames: TArrayOfString;
var
  Block, Cursor: Cardinal;
  Size, Split, Count: Integer;
  Entry, Name: String;
begin
  SetArrayLength(Result, 0);
  Block := GetEnvironmentStringsW;
  if Block = 0 then
    exit;
  try
    Cursor := Block;
    Size := lstrlenW(Cursor);
    while Size > 0 do
    begin
      SetLength(Entry, Size + 1);
      lstrcpynW(Entry, Cursor, Size + 1);
      SetLength(Entry, Size);
      Split := Pos('=', Copy(Entry, 2, Size)) + 1;
      if Split > 1 then
      begin
        Name := Copy(Entry, 1, Split - 1);
        if HasClearedPrefix(Name) then
        begin
          Count := GetArrayLength(Result);
          SetArrayLength(Result, Count + 1);
          Result[Count] := Name;
        end;
      end;
      Cursor := Cursor + Cardinal((Size + 1) * 2);
      Size := lstrlenW(Cursor);
    end;
  finally
    FreeEnvironmentStringsW(Block);
  end;
end;

procedure ClearCodeLoading;
var
  Names: TArrayOfString;
  Index: Integer;
begin
  Names := PrefixedNames;
  for Index := 0 to GetArrayLength(Names) - 1 do
    RemoveEnvironmentVariable(Names[Index], 0);
  Names := ['DOTNET_EnableDiagnostics', 'COMPlus_EnableDiagnostics', 'DOTNET_EnableDiagnostics_IPC', 'COMPlus_EnableDiagnostics_IPC',
    'DOTNET_EnableDiagnostics_Debugger', 'COMPlus_EnableDiagnostics_Debugger', 'DOTNET_EnableDiagnostics_Profiler', 'COMPlus_EnableDiagnostics_Profiler'];
  for Index := 0 to GetArrayLength(Names) - 1 do
    SetEnvironmentVariable(Names[Index], '0');
  SetEnvironmentVariable('PSModulePath', ExpandConstant('{commonpf64}\WindowsPowerShell\Modules;{sys}\WindowsPowerShell\v1.0\Modules'));
end;
