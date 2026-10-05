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

function GetCurrentProcess: THandle; external 'GetCurrentProcess@kernel32.dll stdcall';
function OpenProcessToken(Process: THandle; Access: DWORD; var Token: THandle): BOOL; external 'OpenProcessToken@advapi32.dll stdcall';
function GetUserProfileDirectory(Token: THandle; Buffer: String; var Size: DWORD): BOOL; external 'GetUserProfileDirectoryW@userenv.dll stdcall';
function GetUserNameEx(Format: DWORD; Buffer: String; var Size: DWORD): Byte; external 'GetUserNameExW@secur32.dll stdcall';
function GetActiveProcessorCount(Group: Word): DWORD; external 'GetActiveProcessorCount@kernel32.dll stdcall';

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

function MachineEnvironment(const Name, Default: String): String;
begin
  if not RegQueryStringValue(HKLM64, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', Name, Result) then
    Result := Default;
end;

function FolderAttributes(Path: String): DWORD; external 'GetFileAttributesW@kernel32.dll stdcall';
function FolderDriveType(Path: String): DWORD; external 'GetDriveTypeW@kernel32.dll stdcall';
function FolderFullPath(Path: String; Size: DWORD; Buffer: String; Part: DWORD): DWORD; external 'GetFullPathNameW@kernel32.dll stdcall';
function FolderLongPath(Path: String; Buffer: String; Size: DWORD): DWORD; external 'GetLongPathNameW@kernel32.dll stdcall';

function SetupUserFolder(const Profile: String; const Roaming: Boolean; const InstallFolder: String): String;
var
  Raw, Name, Key, Full, Ancestor, Blocked: String;
  Index, Size: Integer;
  Attributes: DWORD;
  Parts: TArrayOfString;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders';
  Name := 'Local AppData';
  if Roaming then Name := 'AppData';
  if RegValueExists(HKCU, Key, Name) then
  begin
    if not RegQueryStringValue(HKCU, Key, Name, Raw) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
  end
  else
  begin
    Raw := Profile + '\AppData\Local';
    if Roaming then Raw := Profile + '\AppData\Roaming';
  end;
  Result := '';
  Index := 1;
  while Index <= Length(Raw) do
  begin
    if CompareText(Copy(Raw, Index, 13), '%USERPROFILE%') = 0 then
    begin
      Result := Result + Profile;
      Index := Index + 13;
    end
    else
    begin
      Result := Result + Copy(Raw, Index, 1);
      Index := Index + 1;
    end;
  end;
  Index := Pos('%', Result);
  if (Result = '') or ((Index > 0) and (Pos('%', Copy(Result, Index + 1, Length(Result))) > 0)) or (Pos('/', Result) > 0) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
  for Index := 1 to Length(Result) do
    if (Ord(Result[Index]) < 32) or (Pos(Result[Index], '<>"|?*') > 0) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
  while (Length(Result) > 3) and (Copy(Result, Length(Result), 1) = '\') do Delete(Result, Length(Result), 1);
  if Roaming and (Copy(Result, 1, 2) = '\\') then
  begin
    Raw := Copy(Result, 3, Length(Result));
    if (Pos('\', Raw) < 2) or (Pos('\', Raw) = Length(Raw)) or (Pos(':', Raw) > 0) or (Pos('\\', Raw) > 0) or (Pos('\.\', '\' + Raw + '\') > 0) or (Pos('\..\', '\' + Raw + '\') > 0) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
    exit;
  end;
  if (Length(Result) < 4) or (Pos(Uppercase(Copy(Result, 1, 1)), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') = 0) or (Copy(Result, 2, 2) <> ':\') or (Pos(':', Copy(Result, 3, Length(Result))) > 0) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
  SetLength(Full, 32768);
  Size := FolderFullPath(Result, 32768, Full, 0);
  if (Size = 0) or (Size >= 32768) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
  SetLength(Full, Size);
  if CompareText(Full, Result) <> 0 then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
  if not Roaming then
  begin
    if (FolderDriveType(ExtractFileDrive(Result) + '\') <> 3) or not DirExists(Result) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings. Choose an existing local folder on a fixed drive.');
    SetLength(Full, 32768);
    Size := FolderLongPath(Result, Full, 32768);
    if (Size = 0) or (Size >= 32768) then RaiseException('Roo Industries could not read the AppData folder path.');
    SetLength(Full, Size);
    Result := Full;
    Ancestor := Result;
    while Length(Ancestor) > 3 do
    begin
      Attributes := FolderAttributes(Ancestor);
      if (Attributes = $FFFFFFFF) or ((Attributes and $400) <> 0) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings.');
      Ancestor := RemoveBackslashUnlessRoot(ExtractFileDir(Ancestor));
    end;
    Parts := [ExpandConstant('{win}'), ExpandConstant('{commonpf64}'), ExpandConstant('{commonpf32}'), InstallFolder];
    for Index := 0 to GetArrayLength(Parts) - 1 do
    begin
      Blocked := RemoveBackslashUnlessRoot(Parts[Index]);
      SetLength(Full, 32768);
      Size := FolderLongPath(Blocked, Full, 32768);
      if (Size > 0) and (Size < 32768) then begin SetLength(Full, Size); Blocked := Full; end;
      if (CompareText(Result, Blocked) = 0) or (CompareText(Copy(Result, 1, Length(Blocked) + 1), Blocked + '\') = 0) then RaiseException('Roo Industries could not use this Windows user''s AppData folder settings. Choose a folder outside Windows and the app''s install folder.');
    end;
  end;
end;

function SetupEnvironment(const TempFolder: String): String;
var
  Profile, Drive, Domain, Account, PublicFolder, Architecture: String;
  Token: THandle;
  Size: DWORD;
begin
  Token := 0;
  if not OpenProcessToken(GetCurrentProcess, 8, Token) then
    RaiseException('Windows could not read the setup user token.');
  try
    Size := 32768;
    SetLength(Profile, Size);
    if not GetUserProfileDirectory(Token, Profile, Size) then
      RaiseException('Windows could not read the setup user profile.');
    SetLength(Profile, Pos(#0, Profile) - 1);
  finally
    CloseHandle(Token);
  end;
  Drive := ExtractFileDrive(Profile);
  Domain := GetComputerNameString;
  Size := 32768;
  SetLength(Account, Size);
  if GetUserNameEx(2, Account, Size) <> 0 then
  begin
    SetLength(Account, Size);
    if Pos('\', Account) > 0 then Domain := Copy(Account, 1, Pos('\', Account) - 1);
  end;
  if not RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList', 'Public', PublicFolder) then
    RaiseException('Windows could not read the public profile folder.');
  StringChangeEx(PublicFolder, '%SystemDrive%', ExtractFileDrive(ExpandConstant('{win}')), True);
  Architecture := 'AMD64';
  if ProcessorArchitecture = paArm64 then Architecture := 'ARM64';
  if ProcessorArchitecture = paX86 then Architecture := 'x86';
  Result :=
    EnvironmentEntry('ALLUSERSPROFILE', ExpandConstant('{commonappdata}')) +
    EnvironmentEntry('APPDATA', SetupUserFolder(Profile, True, ExtractFileDir(RemoveBackslashUnlessRoot(TempFolder)))) +
    EnvironmentEntry('CommonProgramFiles', ExpandConstant('{commoncf64}')) +
    EnvironmentEntry('CommonProgramFiles(x86)', ExpandConstant('{commoncf32}')) +
    EnvironmentEntry('CommonProgramW6432', ExpandConstant('{commoncf64}')) +
    EnvironmentEntry('COMPlus_EnableDiagnostics', '0') +
    EnvironmentEntry('COMPlus_EnableDiagnostics_Debugger', '0') +
    EnvironmentEntry('COMPlus_EnableDiagnostics_IPC', '0') +
    EnvironmentEntry('COMPlus_EnableDiagnostics_Profiler', '0') +
    EnvironmentEntry('COMPUTERNAME', GetComputerNameString) +
    EnvironmentEntry('ComSpec', ExpandConstant('{sys}\cmd.exe')) +
    EnvironmentEntry('DOTNET_EnableDiagnostics', '0') +
    EnvironmentEntry('DOTNET_EnableDiagnostics_Debugger', '0') +
    EnvironmentEntry('DOTNET_EnableDiagnostics_IPC', '0') +
    EnvironmentEntry('DOTNET_EnableDiagnostics_Profiler', '0') +
    EnvironmentEntry('DriverData', ExpandConstant('{sys}\Drivers\DriverData')) +
    EnvironmentEntry('HOMEDRIVE', Drive) +
    EnvironmentEntry('HOMEPATH', Copy(Profile, Length(Drive) + 1, Length(Profile))) +
    EnvironmentEntry('LOCALAPPDATA', SetupUserFolder(Profile, False, ExtractFileDir(RemoveBackslashUnlessRoot(TempFolder)))) +
    EnvironmentEntry('NUMBER_OF_PROCESSORS', MachineEnvironment('NUMBER_OF_PROCESSORS', IntToStr(GetActiveProcessorCount($FFFF)))) +
    EnvironmentEntry('OS', MachineEnvironment('OS', 'Windows_NT')) +
    EnvironmentEntry('PATH', ExpandConstant('{sys};{win};{sys}\Wbem;{sys}\WindowsPowerShell\v1.0')) +
    EnvironmentEntry('PATHEXT', '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC') +
    EnvironmentEntry('PROCESSOR_ARCHITECTURE', Architecture) +
    EnvironmentEntry('PROCESSOR_IDENTIFIER', MachineEnvironment('PROCESSOR_IDENTIFIER', '')) +
    EnvironmentEntry('PROCESSOR_LEVEL', MachineEnvironment('PROCESSOR_LEVEL', '')) +
    EnvironmentEntry('PROCESSOR_REVISION', MachineEnvironment('PROCESSOR_REVISION', '')) +
    EnvironmentEntry('ProgramData', ExpandConstant('{commonappdata}')) +
    EnvironmentEntry('ProgramFiles', ExpandConstant('{commonpf64}')) +
    EnvironmentEntry('ProgramFiles(x86)', ExpandConstant('{commonpf32}')) +
    EnvironmentEntry('ProgramW6432', ExpandConstant('{commonpf64}')) +
    EnvironmentEntry('PSModulePath', ExpandConstant('{commonpf64}\WindowsPowerShell\Modules;{sys}\WindowsPowerShell\v1.0\Modules')) +
    EnvironmentEntry('PUBLIC', PublicFolder) +
    EnvironmentEntry('SystemDrive', ExtractFileDrive(ExpandConstant('{win}'))) +
    EnvironmentEntry('SystemRoot', ExpandConstant('{win}')) +
    EnvironmentEntry('TEMP', TempFolder) +
    EnvironmentEntry('TMP', TempFolder) +
    EnvironmentEntry('USERDOMAIN', Domain) +
    EnvironmentEntry('USERNAME', GetUserNameString) +
    EnvironmentEntry('USERPROFILE', Profile) +
    EnvironmentEntry('windir', ExpandConstant('{win}')) + #0;
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
  Command, NativeFile, NativeSystem: String;
  Started: DWORD;
begin
  Result := False;
  ExitCode := 1;
  NativeFile := FileName;
  NativeSystem := ExpandConstant('{sys}');
  if IsWin64 then
  begin
    if CompareText(Copy(FileName, 1, Length(NativeSystem) + 1), NativeSystem + '\') = 0 then
      NativeFile := ExpandConstant('{sysnative}') + Copy(FileName, Length(NativeSystem) + 1, Length(FileName));
  end;
  Command := '"' + NativeFile + '" ' + Parameters;
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
  if not CreateProcessW(NativeFile, Command, 0, 0, False, CREATE_UNICODE_ENVIRONMENT or CREATE_NO_WINDOW, SetupEnvironment(TempFolder), NativeSystem, Startup, Process) then
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
