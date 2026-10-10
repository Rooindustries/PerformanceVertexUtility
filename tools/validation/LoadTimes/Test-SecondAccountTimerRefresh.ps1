param(
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$BackupRoot,
    [Parameter(Mandatory)][string]$OldInstaller,
    [Parameter(Mandatory)][string]$CurrentInstaller,
    [Parameter(Mandatory)][string]$NewInstaller,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$NewInstallerSha256,
    [string]$Source = (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent),
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$FailureModes = @(
    'Preflight exits nonzero or lacks its matching result JSON, or another runner phase has no named PASS: retain the runner result and fail.',
    'EnableLUA is missing or invalid, or B startup/helper elevation differs from its recorded expectation: record FAIL without skipping the token check.',
    'Account creation or Administrators membership fails: record FAIL, retain the created SID and remove only that account.',
    'LOGON_WITH_PROFILE fails or loads the wrong profile: record FAIL before any timer request and retain the native error and token identity.',
    'The secondary token is filtered or desktop/UIA access fails: record FAIL; never substitute the main account or claim the dashboard loaded.',
    'Released 0.9 refuses the timer preview/apply: retain request, response, exit and owned identities; stop the scenario and clean the secondary account.',
    'An interactive-token task cannot run without a signed-in secondary account: retain LogonType and trigger SID; use the specified credentialed startup script launch.',
    'An installer has the wrong hash, fails, or rewrites the secondary script: retain stage-specific runner evidence and fail the exact stale-script assertion.',
    'The app fails to refresh, its log rotates, or a second launch changes the task/receipt: retain both log generations, script bytes and native task fingerprints and fail.',
    'The startup hash checks fail or the helper/session identity disagrees: retain the script, session, launch receipt and native process identity; stop only proven owned processes.',
    'Uninstall retains the secondary task or omits its removal log: record FAIL before fixture cleanup, keeping the native uninstall evidence.',
    'Cleanup leaves a loaded profile, account, data, registry State or markers, or finds changed ownership: retain evidence and record FAIL; never delete another account or foreign process.',
    'Runner recovery or the independent audit differs from the exact 9070 baseline: retain per-field differences and FAIL, including State bytes/hash, 349 rows and six CS2 tasks.'
)
if (Test-Path -LiteralPath $OutDir) { throw 'Use a fresh protected evidence directory; previous evidence is retained.' }
[IO.Directory]::CreateDirectory($OutDir) | Out-Null
$script:LogPath = Join-Path $OutDir 'second-account-timer-refresh.log'
$script:Checks = [Collections.Generic.List[object]]::new()
$script:Processes = [Collections.Generic.List[object]]::new()
$script:TaskReceipts = [Collections.Generic.List[object]]::new()
$script:Failures = 0
$script:AccountCreated = $false
$script:AccountSid = $null
$script:ProfilePath = $null
$script:LocalPath = $null
$script:ControlRoot = $null
$script:TimerTaskName = $null
$script:FullToken = [IntPtr]::Zero
$script:DesktopGrants = @()
$script:RecoveryOpened = $false
$script:Uninstalled = $false
$script:BeforeAudit = $null
$script:CurrentStage = 'preconditions'
$script:StartedUtc = [DateTime]::UtcNow
$script:Password = $null
$script:EnableLUA = $null
$script:ExpectedStartupElevated = $null
$accountName = 'RooF2_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$install = Split-Path (Split-Path $Exe -Parent) -Parent
$hostExe = Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$system = [Environment]::GetFolderPath('System')
$powershell = Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'
$runner = Join-Path $Source 'tools\validation\Release\Invoke-IntegrationVerification.ps1'
$markerPath = 'SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'

function Log([string]$Message) { [IO.File]::AppendAllText($script:LogPath, [DateTime]::UtcNow.ToString('o') + ' ' + $Message + [Environment]::NewLine) }
function Save-Json([string]$Name, $Value) { ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath (Join-Path $OutDir $Name) -Encoding UTF8 }
function Save-Result {
    Save-Json 'second-account-timer-refresh-result.json' ([ordered]@{
        scenario = 'second-account-timer-refresh'; machine = $env:COMPUTERNAME
        startedUtc = $script:StartedUtc.ToString('o'); observedUtc = [DateTime]::UtcNow.ToString('o')
        stage = $script:CurrentStage; passed = ($script:CurrentStage -ceq 'complete' -and $script:Failures -eq 0)
        failures = $script:Failures; account = $accountName; sid = $script:AccountSid
        enableLUA = $script:EnableLUA; expectedStartupElevated = $script:ExpectedStartupElevated
        failureModes = $FailureModes; checks = $script:Checks.ToArray()
        processes = @($script:Processes | ForEach-Object { $_.Identity }); log = $script:LogPath
    })
}
function Check([bool]$Ok, [string]$Name, [string]$Detail = '') {
    if (-not $Ok) { $script:Failures++ }
    $script:Checks.Add([ordered]@{ name = $Name; passed = $Ok; stage = $script:CurrentStage; detail = $Detail })
    Log ($(if ($Ok) { 'PASS ' } else { 'FAIL ' }) + $Name + ' :: ' + $Detail)
    Save-Result
}
function Require([bool]$Ok, [string]$Name, [string]$Detail = '') {
    Check $Ok $Name $Detail
    if (-not $Ok) { throw $Name }
}
function WaitFor([scriptblock]$Probe, [int]$Seconds, [string]$What) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastError = ''
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        try { $value = & $Probe; if ($value) { return $value } } catch { $lastError = $_.Exception.Message }
        Start-Sleep -Milliseconds 200
    }
    throw ('Timed out waiting for ' + $What + '. ' + $lastError)
}
function Hash-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') } finally { $sha.Dispose() }
}
function Literal([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
function Command-Argument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Resolve-Sid([string]$Value) {
    try { [Security.Principal.SecurityIdentifier]::new($Value).Value }
    catch { [Security.Principal.NTAccount]::new($Value).Translate([Security.Principal.SecurityIdentifier]).Value }
}

try {
    Require ($env:OS -ceq 'Windows_NT' -and $env:COMPUTERNAME -ceq 'SERVI-WINDOWS-D') 'the scenario is running only on optimizer-9070' $env:COMPUTERNAME
    Require ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'the main account is elevated'
    $script:EnableLUA = (Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA
    Require ($script:EnableLUA -in 0, 1) 'EnableLUA is recorded as 0 or 1' ('EnableLUA=' + $script:EnableLUA)
    $script:ExpectedStartupElevated = ($script:EnableLUA -eq 0)
    Check $true 'B startup and helper elevation expectation is recorded' ('EnableLUA=' + $script:EnableLUA + ' expectedElevated=' + $script:ExpectedStartupElevated)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $OutDir -AclObject $acl
    . (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Xml.Linq
    Add-Type @'
using System;
using System.Text;
using System.Security;
using System.ComponentModel;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.AccessControl;
public static class SecondAccountNative {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 public struct Startup { public int cb; public string reserved, desktop, title; public int x,y,width,height,cx,cy,fill,flags; public short show,bytes; public IntPtr extra,input,output,error; }
 [StructLayout(LayoutKind.Sequential)]
 public struct Launch { public IntPtr process,thread; public int pid,tid; }
 public sealed class DesktopGrant { public IntPtr handle; public byte[] before,applied; }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern bool CreateProcessWithLogonW(string user,string domain,IntPtr password,int logon,string exe,StringBuilder command,int flags,IntPtr env,string cwd,ref Startup startup,out Launch launch);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern bool CreateProcessWithTokenW(IntPtr token,int logon,string exe,StringBuilder command,int flags,IntPtr env,string cwd,ref Startup startup,out Launch launch);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,IntPtr value,int length,out int returned);
 [DllImport("userenv.dll",SetLastError=true)] static extern bool CreateEnvironmentBlock(out IntPtr block,IntPtr token,bool inherit);
 [DllImport("userenv.dll")] static extern bool DestroyEnvironmentBlock(IntPtr block);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out int code);
 [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr GetThreadDesktop(uint thread);
 [DllImport("user32.dll",SetLastError=true)] static extern bool GetUserObjectSecurity(IntPtr handle,ref uint info,byte[] bytes,uint length,out uint needed);
 [DllImport("user32.dll",SetLastError=true)] static extern bool SetUserObjectSecurity(IntPtr handle,ref uint info,byte[] bytes);
 [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CommandLineToArgvW(string command,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
 static Startup Info() { return new Startup { cb=Marshal.SizeOf(typeof(Startup)), desktop=@"winsta0\default", flags=1, show=1 }; }
 public static Launch Logon(string user,SecureString password,string exe,string command,string cwd) {
  if(command.Length>=1024) throw new InvalidOperationException("Credentialed command exceeds the documented 1024-character limit.");
  IntPtr secret=Marshal.SecureStringToGlobalAllocUnicode(password);
  try { Launch launch; var info=Info(); Check(CreateProcessWithLogonW(user,Environment.MachineName,secret,1,exe,new StringBuilder(command),0x08000424,IntPtr.Zero,cwd,ref info,out launch)); return launch; }
  finally { Marshal.ZeroFreeGlobalAllocUnicode(secret); }
 }
 public static Launch Elevated(IntPtr token,string exe,string command,string cwd) {
  if(command.Length>=1024) throw new InvalidOperationException("Credentialed command exceeds the documented 1024-character limit.");
  IntPtr env; Check(CreateEnvironmentBlock(out env,token,false));
  try { Launch launch; var info=Info(); Check(CreateProcessWithTokenW(token,1,exe,new StringBuilder(command),0x08000424,env,cwd,ref info,out launch)); return launch; }
  finally { DestroyEnvironmentBlock(env); }
 }
 static int TokenInt(IntPtr token,int kind) {
  IntPtr value=Marshal.AllocHGlobal(4);
  try { int returned; Check(GetTokenInformation(token,kind,value,4,out returned)); return Marshal.ReadInt32(value); }
  finally { Marshal.FreeHGlobal(value); }
 }
 public static IntPtr FullToken(IntPtr process,string sid) {
  IntPtr token; Check(OpenProcessToken(process,0xB,out token));
  try {
   if(TokenInt(token,20)==0) {
    IntPtr value=Marshal.AllocHGlobal(IntPtr.Size);
    try { int returned; Check(GetTokenInformation(token,19,value,IntPtr.Size,out returned)); IntPtr linked=Marshal.ReadIntPtr(value); CloseHandle(token); token=linked; }
    finally { Marshal.FreeHGlobal(value); }
   }
   using(var identity=new WindowsIdentity(token)) { if(identity.User.Value!=sid || TokenInt(token,20)!=1) throw new InvalidOperationException("The secondary token is not its own elevated administrator token."); }
   IntPtr result=token; token=IntPtr.Zero; return result;
  } finally { if(token!=IntPtr.Zero) CloseHandle(token); }
 }
 public static string ProcessSid(IntPtr process) {
  IntPtr token; Check(OpenProcessToken(process,8,out token));
  try { using(var identity=new WindowsIdentity(token)) return identity.User.Value; } finally { CloseHandle(token); }
 }
 public static bool IsElevated(IntPtr process) {
  IntPtr token; Check(OpenProcessToken(process,8,out token));
  try { return TokenInt(token,20)==1; } finally { CloseHandle(token); }
 }
 public static Dictionary<string,string> EnvironmentFor(IntPtr token) {
  IntPtr env; Check(CreateEnvironmentBlock(out env,token,false));
  try { var values=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase); int offset=0;
   while(Marshal.ReadInt16(env,offset)!=0) { string item=Marshal.PtrToStringUni(IntPtr.Add(env,offset)); offset+=(item.Length+1)*2; int equals=item.IndexOf('='); if(equals>0) values[item.Substring(0,equals)]=item.Substring(equals+1); }
   return values;
  } finally { DestroyEnvironmentBlock(env); }
 }
 public static int Exit(IntPtr process) { int code; Check(GetExitCodeProcess(process,out code)); return code; }
 public static IntPtr Station() { return GetProcessWindowStation(); }
 public static IntPtr Desktop() { return GetThreadDesktop(GetCurrentThreadId()); }
 public static byte[] Security(IntPtr handle) {
  uint info=4,needed; GetUserObjectSecurity(handle,ref info,null,0,out needed);
  if(needed==0) throw new Win32Exception(Marshal.GetLastWin32Error());
  var bytes=new byte[needed]; Check(GetUserObjectSecurity(handle,ref info,bytes,needed,out needed)); return bytes;
 }
 public static DesktopGrant Grant(IntPtr handle,string sid,int access) {
  var before=Security(handle); var sd=new RawSecurityDescriptor(before,0);
  if(sd.DiscretionaryAcl==null) throw new InvalidOperationException("A null desktop DACL is not an owned fixture.");
  sd.DiscretionaryAcl.InsertAce(sd.DiscretionaryAcl.Count,new CommonAce(AceFlags.None,AceQualifier.AccessAllowed,access,new SecurityIdentifier(sid),false,null));
  var bytes=new byte[sd.BinaryLength]; sd.GetBinaryForm(bytes,0); uint info=4;
  Check(SetUserObjectSecurity(handle,ref info,bytes));
  return new DesktopGrant {handle=handle,before=before,applied=Security(handle)};
 }
 public static void Restore(DesktopGrant grant) {
  if(Convert.ToBase64String(Security(grant.handle))!=Convert.ToBase64String(grant.applied)) throw new InvalidOperationException("Desktop security changed concurrently; original descriptor retained.");
  uint info=4; Check(SetUserObjectSecurity(grant.handle,ref info,grant.before));
  if(Convert.ToBase64String(Security(grant.handle))!=Convert.ToBase64String(grant.before)) throw new InvalidOperationException("Desktop security did not restore exactly.");
 }
 public static string[] Arguments(string command) {
  int count; IntPtr memory=CommandLineToArgvW(command,out count); Check(memory!=IntPtr.Zero);
  try { var args=new string[count]; for(int i=0;i<count;i++) args[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size)); return args; }
  finally { LocalFree(memory); }
 }
}
'@
    function Start-Secondary([string]$Name, [string]$File, [string[]]$ArgumentList, [switch]$Logon) {
        $command = ((@($File) + $ArgumentList | ForEach-Object { Command-Argument $_ }) -join ' ')
        $credentialed = $Logon -or $script:EnableLUA -eq 0
        $launch = if ($credentialed) {
            [SecondAccountNative]::Logon($accountName, $script:Password, $File, $command, (Split-Path $File -Parent))
        } else {
            [SecondAccountNative]::Elevated($script:FullToken, $File, $command, (Split-Path $File -Parent))
        }
        $process = [Diagnostics.Process]::GetProcessById($launch.pid)
        [void]$process.Handle
        $receipt = [pscustomobject]@{
            process = $process; handle = $launch.process; native = $launch; name = $Name
            Identity = [pscustomobject]@{
                pid = $launch.pid; creationTimeFileTimeUtc = [RooValidationOwnership.Native]::Created($launch.process).ToString()
                imagePath = [RooValidationOwnership.Native]::Image($launch.process)
            }
        }
        $script:Processes.Add($receipt)
        Save-Json ($Name + '-process.json') ([ordered]@{
            identity = $receipt.Identity; commandLine = $command
            sid = [SecondAccountNative]::ProcessSid($launch.process)
            elevated = [SecondAccountNative]::IsElevated($launch.process); logonWithProfile = $true
            transport = $(if ($credentialed) { 'CreateProcessWithLogonW' } else { 'CreateProcessWithTokenW: secondary linked administrator token' })
        })
        Require ([SecondAccountNative]::ProcessSid($launch.process) -ceq $script:AccountSid) ($Name + ' runs as B') $script:AccountSid
        if (-not $Logon) { Require ([SecondAccountNative]::IsElevated($launch.process)) ($Name + ' runs elevated as B') }
        Require ([SecondAccountNative]::ResumeThread($launch.thread) -ne [uint32]::MaxValue) ($Name + ' starts with a retained native identity')
        $receipt
    }
    function Stop-Receipt($Receipt) {
        if ($Receipt -and -not $Receipt.process.HasExited) { Stop-OwnedProcess $Receipt }
    }
    function Run-Runner([string]$Phase, [string]$Label, [hashtable]$Extra = @{}) {
        $dir = Join-Path $OutDir ('runner-' + $Label)
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        if ($Phase -ceq 'upgrade') {
            Copy-Item -LiteralPath (Join-Path $OutDir 'runner-install-old\installed-old.json') -Destination (Join-Path $dir 'installed-old.json')
        }
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runner,
            '-Phase', $Phase, '-Source', $Source, '-Evidence', $dir, '-BackupRoot', $BackupRoot)
        foreach ($name in $Extra.Keys) { $arguments += @(('-' + $name), [string]$Extra[$name]) }
        $start = @{
            FilePath = $powershell; ArgumentList = @( $arguments | ForEach-Object { Command-Argument $_ })
            PassThru = $true; WindowStyle = 'Hidden'
            RedirectStandardOutput = (Join-Path $OutDir ('runner-' + $Label + '-console.out'))
            RedirectStandardError = (Join-Path $OutDir ('runner-' + $Label + '-console.err'))
        }
        $process = Start-Process @start
        $owned = New-OwnedProcess $process
        if (-not $owned) { throw 'Runner exited before its native identity could be retained.' }
        $script:Processes.Add($owned)
        Save-Json ('runner-' + $Label + '-process.json') $owned.Identity
        if (-not $process.WaitForExit(5400000)) {
            Stop-Receipt $owned
            throw ('Runner timed out in ' + $Label + '; sealed recovery and child evidence retained.')
        }
        $lines = @([IO.File]::ReadAllLines((Join-Path $dir ($Phase + '.log'))))
        $named = @($lines | Where-Object { $_ -cmatch '^\S+ PASS ' })
        $errors = @($lines | Where-Object { $_ -cmatch '^\S+ (FAIL|FATAL|ERROR|SKIPPED|NOT RUN) ' })
        Save-Json ('runner-' + $Label + '-result.json') ([ordered]@{
            phase = $Phase; exit = $process.ExitCode; identity = $owned.Identity; checks = $named
            log = (Join-Path $dir ($Phase + '.log')); logSha256 = (Get-FileHash -LiteralPath (Join-Path $dir ($Phase + '.log'))).Hash
        })
        if ($Phase -eq 'preflight') {
            $resultPath = Join-Path $OutDir ('runner-' + $Label + '-result.json')
            $result = Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json
            Require ($result.phase -ceq $Phase -and $result.exit -eq 0 -and
                $result.logSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $dir ($Phase + '.log'))).Hash) 'runner preflight result JSON records this successful invocation' $resultPath
        }
        Require ($process.ExitCode -eq 0 -and $errors.Count -eq 0 -and ($named.Count -gt 0 -or $Phase -eq 'preflight')) ('runner ' + $Label + ' completed its named checks') ('exit=' + $process.ExitCode + ' log=' + $dir)
        $dir
    }
    function Run-OldHost([string]$Action, [hashtable]$Fields) {
        $stem = Join-Path $OutDir ('old-' + $Action)
        $request = @{ schemaVersion = 1; repoRoot = $install }
        foreach ($name in $Fields.Keys) { $request[$name] = $Fields[$name] }
        [IO.File]::WriteAllText(($stem + '.request.json'), ($request | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $body = '$ErrorActionPreference = ''Stop''; . ' + (Literal (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')) + [char]10 +
            '$start = [Diagnostics.ProcessStartInfo]::new(); $start.FileName = ' + (Literal $hostExe) +
            '; $start.Arguments = ' + (Literal ($Action + ' "' + $stem + '.request.json"')) +
            '; $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.CreateNoWindow = $true' + [char]10 +
            '$process = [Diagnostics.Process]::Start($start); $owned = New-OwnedProcess $process; if (-not $owned) { throw ''Old Host exited before its identity was retained'' }; $owned.Identity | ConvertTo-Json | Set-Content -LiteralPath ' + (Literal ($stem + '.host-process.json')) + ' -Encoding UTF8' + [char]10 +
            '$out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync(); if (-not $process.WaitForExit(180000)) { Stop-OwnedProcess $owned; throw ''Old Host timed out'' }; $out.Result | Set-Content -LiteralPath ' + (Literal ($stem + '.out')) + ' -Encoding UTF8; $err.Result | Set-Content -LiteralPath ' + (Literal ($stem + '.err')) + ' -Encoding UTF8; $process.ExitCode | Set-Content -LiteralPath ' + (Literal ($stem + '.exit')) + '; exit $process.ExitCode'
        [IO.File]::WriteAllText(($stem + '.ps1'), $body, [Text.UTF8Encoding]::new($true))
        $child = Start-Secondary ('old-' + $Action) $powershell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ($stem + '.ps1'))
        if (-not $child.process.WaitForExit(210000)) { Stop-Receipt $child; throw ('Old Host wrapper timed out: ' + $Action) }
        $code = if (Test-Path -LiteralPath ($stem + '.exit')) { [int](Get-Content -LiteralPath ($stem + '.exit') -Raw) } else { -1 }
        Require ($child.process.ExitCode -eq 0 -and $code -eq 0) ('0.9 B ' + $Action + ' completed') ('wrapper=' + $child.process.ExitCode + ' host=' + $code + ' evidence=' + $stem)
        $reply = Get-Content -LiteralPath ($stem + '.out') -Raw | ConvertFrom-Json
        Require ($reply.status -ceq 'completed' -and $null -ne $reply.data) ('0.9 B ' + $Action + ' returned completed data') ($stem + '.out')
        $reply.data
    }
    function Timer-Evidence([string]$Name) {
        $scriptPath = Join-Path $script:ControlRoot 'startup.ps1'
        $receiptPath = Join-Path $script:ControlRoot 'startup.json'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $task = Get-OwnedTaskReceipt $script:TimerTaskName '\'
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder = $service.GetFolder('\')
        $nativeTask = $folder.GetTask($script:TimerTaskName)
        $definition = $nativeTask.Definition
        $principal = $definition.Principal; $triggers = $definition.Triggers; $actions = $definition.Actions
        $trigger = $triggers.Item(1); $action = $actions.Item(1)
        try {
            $xml = [Xml.Linq.XDocument]::Parse($task.xml)
            $enabled = $xml.Root.Element($xml.Root.Name.Namespace + 'Settings').Element($xml.Root.Name.Namespace + 'Enabled')
            if ($enabled) { $enabled.Remove() }
            $fingerprint = Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($xml.ToString([Xml.Linq.SaveOptions]::DisableFormatting) + [char]10 + $task.sddl))
            $evidence = [ordered]@{
                task = $task; definitionHash = $fingerprint; principalSid = (Resolve-Sid ([string]$principal.UserId))
                triggerSid = (Resolve-Sid ([string]$trigger.UserId)); logonType = [int]$principal.LogonType
                runLevel = [int]$principal.RunLevel; triggerType = [int]$trigger.Type; triggers = [int]$triggers.Count
                actions = [int]$actions.Count; actionType = [int]$action.Type; execute = [string]$action.Path
                arguments = [string]$action.Arguments; workingDirectory = [string]$action.WorkingDirectory
                scriptSha256 = (Get-FileHash -LiteralPath $scriptPath).Hash; scriptBytes = (Get-Item -LiteralPath $scriptPath).Length
                receiptSha256 = (Get-FileHash -LiteralPath $receiptPath).Hash; receipt = $receipt
                expectedSha256 = (Hash-Bytes (Expected-TimerStartup $script:ControlRoot))
            }
            Save-Json ($Name + '-timer.json') $evidence
            Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $OutDir ($Name + '-startup.ps1'))
            Copy-Item -LiteralPath $receiptPath -Destination (Join-Path $OutDir ($Name + '-startup.json'))
            $script:TaskReceipts.Add($task)
            $expectedArguments = '--headless "' + $powershell + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
            Require ($receipt.owner.userSid -ceq $script:AccountSid -and $receipt.owner.machine -ieq $env:COMPUTERNAME -and
                $receipt.taskName -ceq $script:TimerTaskName -and $receipt.phase -ceq 'created' -and
                $receipt.scriptHash -ieq $evidence.scriptSha256 -and $receipt.definitionHash -ieq $fingerprint) ($Name + ' has a created B receipt matching script and native task') ($Name + '-timer.json')
            Require ($evidence.principalSid -ceq $script:AccountSid -and $evidence.triggerSid -ceq $script:AccountSid -and
                $evidence.logonType -eq 3 -and $evidence.runLevel -eq 0 -and $evidence.triggerType -eq 9 -and $evidence.triggers -eq 1 -and
                $evidence.actions -eq 1 -and $evidence.actionType -eq 0 -and $evidence.execute -ieq (Join-Path $system 'conhost.exe') -and
                $evidence.arguments -ceq $expectedArguments -and -not $evidence.workingDirectory -and $nativeTask.Enabled) ($Name + ' has the exact B interactive sign-in task and startup action') ($Name + '-timer.json')
            $evidence
        } finally {
            foreach ($com in $action, $trigger, $actions, $triggers, $principal, $definition, $nativeTask, $folder, $service) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com)
            }
        }
    }
    function Capture-TimerWorker([string]$Name, [DateTime]$StartedAfter, [string]$LaunchKind) {
        $sessionPath = if ($LaunchKind -ceq 'worker') { Join-Path $script:ControlRoot 'session.json' } else { Join-Path $script:LocalPath 'RooIndustriesOptimizationSuite.Timer\session.json' }
        $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
        if (-not $session.acquired -or $session.released -or $null -ne $session.error -or
            $null -eq $session.acquireStatus -or $session.acquireStatus -lt 0 -or
            $session.launch.owner.userSid -cne $script:AccountSid -or $session.launch.owner.machine -ine $env:COMPUTERNAME -or
            $session.launch.root -ine $script:ControlRoot -or -not $session.launch.sessionId -or
            $session.launch.assemblyPath -ine (Join-Path (Split-Path $hostExe -Parent) 'Optimizer.Host.dll') -or
            $session.launch.assemblyHash -ine (Get-FileHash -LiteralPath $session.launch.assemblyPath).Hash) { throw 'No matching active B timer acquisition and installed launch receipt.' }
        $row = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$session.processId) -ErrorAction Stop
        $args = [SecondAccountNative]::Arguments([string]$row.CommandLine)
        $process = Get-Process -Id $session.processId -ErrorAction Stop
        $owned = New-OwnedProcess $process
        if (-not $owned) { throw 'B timer helper exited before its identity could be retained.' }
        if ($owned.Identity.creationTimeFileTimeUtc -cne [string]$session.creationTime -or
            $owned.Identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($hostExe) -or
            [SecondAccountNative]::ProcessSid($owned.handle) -cne $script:AccountSid -or $process.StartTime.ToUniversalTime() -lt $StartedAfter -or
            $args.Count -ne 3 -or $args[0] -ine $hostExe -or $args[1] -cne ('--timer-' + $LaunchKind) -or $row.ExecutablePath -ine $hostExe -or
            ($LaunchKind -ceq 'worker' -and $args[2] -ine (Join-Path $script:ControlRoot 'launch.json'))) {
            $process.Dispose()
            throw 'B timer helper native identity, SID or command contradicts its session receipt; retained.'
        }
        $script:Processes.Add($owned)
        Save-Json ($Name + '-worker.json') ([ordered]@{identity=$owned.Identity;sid=$script:AccountSid;parentPid=$row.ParentProcessId;commandLine=$row.CommandLine;session=$session})
        if ($LaunchKind -ceq 'autostart') {
            $launchPath = Join-Path (Split-Path $sessionPath -Parent) 'launch.json'
            $launch = Get-Content -LiteralPath $launchPath -Raw | ConvertFrom-Json
            if ($args[2] -ine $script:ControlRoot -or $session.executable -ine $hostExe -or
                $launch.owner.userSid -cne $script:AccountSid -or $launch.owner.machine -ine $env:COMPUTERNAME -or
                $launch.root -ine $script:ControlRoot -or $launch.assemblyPath -ine (Join-Path (Split-Path $hostExe -Parent) 'Optimizer.Host.dll') -or
                $launch.assemblyHash -ine (Get-FileHash -LiteralPath $launch.assemblyPath).Hash -or
                ($session.launch | ConvertTo-Json -Depth 12 -Compress) -cne ($launch | ConvertTo-Json -Depth 12 -Compress)) {
                throw 'Autostart launch and session receipts disagree with the installed B helper; owned identity retained.'
            }
            Save-Json ($Name + '-launch.json') $launch
        }
        $owned
    }
    function Capture-AppChildren($App) {
        $parents = @($App.Identity.pid)
        $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        for ($level = 0; $level -lt 12 -and $parents.Count; $level++) {
            $children = @($rows | Where-Object { $_.ParentProcessId -in $parents -and $_.CreationDate.ToUniversalTime() -ge $App.process.StartTime.ToUniversalTime() })
            $parents = @()
            foreach ($row in $children) {
                $process = Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
                if (-not $process) { continue }
                $owned = New-OwnedProcess $process
                if (-not $owned) { $process.Dispose(); continue }
                $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $row.ProcessId) -ErrorAction Stop
                if (-not $current -or $current.CreationDate -ne $row.CreationDate -or
                    $current.ExecutablePath -ine $row.ExecutablePath -or $current.ParentProcessId -ne $row.ParentProcessId -or
                    $current.CommandLine -cne $row.CommandLine -or $owned.Identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($row.ExecutablePath) -or
                    [SecondAccountNative]::ProcessSid($owned.handle) -cne $script:AccountSid) {
                    $process.Dispose(); throw 'App child native creation or SID changed; retained.'
                }
                if (-not @($script:Processes | Where-Object { $_.Identity.creationTimeFileTimeUtc -ceq $owned.Identity.creationTimeFileTimeUtc -and $_.Identity.pid -eq $owned.Identity.pid }).Count) {
                    $script:Processes.Add($owned)
                    Save-Json ('app-child-' + $owned.Identity.pid + '-' + $owned.Identity.creationTimeFileTimeUtc + '.json') ([ordered]@{identity=$owned.Identity;parent=$row.ParentProcessId;commandLine=$row.CommandLine})
                    $owned
                } else { $process.Dispose() }
                $parents += $row.ProcessId
            }
        }
    }
    function Launch-App([string]$Name) {
        $logPaths = @((Join-Path (Split-Path (Split-Path $script:ControlRoot -Parent) -Parent) 'logs\app.log'),
            (Join-Path (Split-Path (Split-Path $script:ControlRoot -Parent) -Parent) 'logs\app.log.old'))
        foreach ($path in $logPaths) {
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $OutDir ($Name + '-before-' + [IO.Path]::GetFileName($path))) }
        }
        $app = Start-Secondary $Name $Exe @()
        try {
            $a = [Windows.Automation.AutomationElement]
            $window = WaitFor {
                if ($app.process.HasExited) { throw ('B app exited with ' + $app.process.ExitCode) }
                @($a::RootElement.FindAll([Windows.Automation.TreeScope]::Children,
                    [Windows.Automation.PropertyCondition]::new($a::ProcessIdProperty, $app.Identity.pid)) |
                    Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0]
            } 60 ('UIA access to B main window for ' + $Name)
            $dashboard = WaitFor { $window.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new($a::NameProperty, 'Start here')) } 60 ('B dashboard for ' + $Name)
            Save-Json ($Name + '-dashboard.json') ([ordered]@{
                identity=$app.Identity;sid=$script:AccountSid;windowName=$window.Current.Name
                windowHandle=$window.Current.NativeWindowHandle;dashboard=$dashboard.Current.Name
                loadedUtc=[DateTime]::UtcNow.ToString('o');waitSeconds=60
            })
            Check $true ($Name + ' dashboard is reachable through UIA as B')
            Start-Sleep -Seconds 60
        } finally {
            $children = @(Capture-AppChildren $app)
            if (-not $app.process.HasExited) {
                $app.process.CloseMainWindow() | Out-Null
                if (-not $app.process.WaitForExit(20000)) { Stop-Receipt $app }
            }
            foreach ($child in $children) {
                if (-not $child.process.WaitForExit(10000)) { Stop-Receipt $child }
            }
            foreach ($path in $logPaths) {
                if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $OutDir ($Name + '-after-' + [IO.Path]::GetFileName($path))) }
            }
        }
        $newLines = @(foreach ($path in $logPaths) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $before = Join-Path $OutDir ($Name + '-before-' + [IO.Path]::GetFileName($path))
            $oldText = if (Test-Path -LiteralPath $before) { [IO.File]::ReadAllText($before) } else { '' }
            $text = [IO.File]::ReadAllText($path)
            if ($text.StartsWith($oldText, [StringComparison]::Ordinal)) { $text = $text.Substring($oldText.Length) }
            foreach ($line in ($text -split '\r?\n')) {
                if ($line -cmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ' -and
                    [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() -ge
                    $app.process.StartTime.ToUniversalTime().AddSeconds(-1)) { $line }
            }
        })
        Save-Json ($Name + '-new-log-lines.json') $newLines
        $newLines
    }
    function Registry-Audit([string]$Path) {
        $key = Get-Item -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\' + $Path) -ErrorAction SilentlyContinue
        if (-not $key) { return '<absent>' }
        $rows = @(foreach ($item in (@($key) + @(Get-ChildItem -LiteralPath $key.PSPath -Recurse -ErrorAction Stop) | Sort-Object Name)) {
            [ordered]@{ key=$item.Name; name=$null; sddl=$item.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group') }
            foreach ($name in @($item.GetValueNames() | Sort-Object)) {
                $value = $item.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                [ordered]@{
                    key=$item.Name; name=$name; kind=[string]$item.GetValueKind($name)
                    valueSha256=$(if ($value -is [byte[]]) { Hash-Bytes $value } else { Hash-Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Depth 15 -Compress))) })
                }
            }
        })
        Hash-Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $rows -Depth 20 -Compress)))
    }
    function Independent-Audit {
        $mainSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $key = Get-Item -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustriesOptimizationSuite\Tweaks\' + $mainSid)
        $bytes = $key.GetValue('State', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($bytes -isnot [byte[]]) { throw 'Main account State is not binary; independent audit refuses.' }
        $local = [Environment]::GetFolderPath('LocalApplicationData')
        $siblings = @(Get-ChildItem -LiteralPath $local -Directory -Force | Where-Object Name -like 'Roo*OptimizationSuite*' | Sort-Object Name | ForEach-Object Name)
        $rows = @(foreach ($name in $siblings) {
            $root = Join-Path $local $name
            $items = @(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
            foreach ($item in ($items | Sort-Object FullName)) {
                $item.Refresh()
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Independent audit refuses a reparse point.' }
                $security = Get-Acl -LiteralPath $item.FullName -Audit
                [ordered]@{
                    root=$name; relative=$item.FullName.Substring($root.Length); directory=[bool]$item.PSIsContainer
                    length=$(if ($item.PSIsContainer) { 0 } else { $item.Length })
                    creation=$item.CreationTimeUtc.Ticks.ToString(); write=$item.LastWriteTimeUtc.Ticks.ToString()
                    attributes=[int]$item.Attributes; sha256=$(if ($item.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $item.FullName).Hash })
                    sddl=$security.Sddl; descriptor=[Convert]::ToBase64String($security.GetSecurityDescriptorBinaryForm())
                }
            }
        })
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -like 'RooIndustriesCS2_*' | Sort-Object TaskPath,TaskName | ForEach-Object { Get-OwnedTaskReceipt $_.TaskName $_.TaskPath })
        $uninstall = @(foreach ($parent in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            Get-ChildItem -LiteralPath $parent | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } |
                Where-Object DisplayName -like '*Optimization Suite*' | Sort-Object PSPath |
                ForEach-Object { [ordered]@{name=$_.DisplayName;path=$_.PSPath;version=$_.DisplayVersion} }
        })
        [ordered]@{
            machine=$env:COMPUTERNAME; sid=$mainSid
            state=[ordered]@{kind=[string]$key.GetValueKind('State');length=$bytes.Length;sha256=(Hash-Bytes $bytes)}
            tasks=$tasks; siblings=$siblings; dataRows=$rows; appFolder=(Test-Path -LiteralPath $install); uninstall=$uninstall
            productTasks=@(Get-ScheduledTask | Where-Object {
                $_.TaskName -like '*OptimizationSuite.ProcessRules.*' -or $_.TaskName -like 'Roo Industries Protected Session*' -or
                $_.TaskName -like 'RooIndustries.WindowsTimer*' -or $_.TaskName -like 'RooIndustries.Timer.*'
            } | Sort-Object TaskPath,TaskName | ForEach-Object { $_.TaskPath + $_.TaskName })
            productProcesses=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like ($install + '\*') } |
                Sort-Object ProcessId | ForEach-Object { [ordered]@{pid=$_.ProcessId;image=$_.ExecutablePath;created=$_.CreationDate.ToUniversalTime().ToString('o')} })
            registryProduct=(Registry-Audit 'SOFTWARE\RooIndustriesOptimizationSuite')
            registryRoots=(Registry-Audit 'SOFTWARE\RooIndustries')
            accounts=@(Get-LocalUser | Sort-Object Name | ForEach-Object { [ordered]@{name=$_.Name;sid=$_.SID.Value;enabled=$_.Enabled} })
            profiles=@(Get-CimInstance Win32_UserProfile | Sort-Object SID | ForEach-Object { [ordered]@{sid=$_.SID;path=$_.LocalPath} })
            downloadBlockerFolder=(Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'LogiDownloadAssistant'))
        }
    }
    function Cleanup-Secondary {
        if (-not $script:AccountCreated) { return }
        $account = Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue
        if ($account -and $account.SID.Value -cne $script:AccountSid) { throw 'Temporary account SID changed; account/profile retained.' }
        if ($script:TimerTaskName) {
            $task = Get-ScheduledTask -TaskName $script:TimerTaskName -TaskPath '\' -ErrorAction SilentlyContinue
            if ($task) {
                $receipt = @($script:TaskReceipts | Select-Object -Last 1)[0]
                if (-not $receipt) {
                    $principal = Resolve-Sid ([string]$task.Principal.UserId)
                    if ($principal -cne $script:AccountSid) { throw 'Unreceipted timer task belongs to another SID; retained.' }
                    $receipt = Get-OwnedTaskReceipt $script:TimerTaskName '\'
                    Save-Json 'cleanup-partial-task.json' $receipt
                }
                Remove-OwnedTask $receipt
            }
        }
        $profiles = @(Get-CimInstance Win32_UserProfile -Filter ("SID='" + $script:AccountSid + "'"))
        foreach ($profile in $profiles) {
            if ($script:ProfilePath -and $profile.LocalPath -ine $script:ProfilePath) { throw 'B profile path changed; retained.' }
            if ($profile.Loaded) {
                WaitFor {
                    $current = Get-CimInstance Win32_UserProfile -Filter ("SID='" + $script:AccountSid + "'")
                    if (-not $current -or -not $current.Loaded) { $true }
                } 90 'B profile to unload before Win32_UserProfile.Delete' | Out-Null
            }
            $current = Get-CimInstance Win32_UserProfile -Filter ("SID='" + $script:AccountSid + "'")
            if ($current) { Remove-CimInstance -InputObject $current -ErrorAction Stop }
        }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $markers = $base.OpenSubKey($markerPath, $true)
            if ($markers) {
                try {
                    foreach ($name in @($markers.GetValueNames())) {
                        if ($markers.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $script:AccountSid) { continue }
                        if (-not $script:ProfilePath -or -not $name.StartsWith(($script:ProfilePath + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                            throw 'A B marker points outside its created profile; retained.'
                        }
                        $markers.DeleteValue($name, $false)
                        $markers.DeleteValue(($name + '|protected-at'), $false)
                    }
                } finally { $markers.Dispose() }
            }
            foreach ($root in 'SOFTWARE\RooIndustriesOptimizationSuite\Tweaks', 'SOFTWARE\RooOptimizationSuite\Tweaks') {
                $parent = $base.OpenSubKey($root, $true)
                if ($parent) { try { $parent.DeleteSubKeyTree($script:AccountSid, $false) } finally { $parent.Dispose() } }
            }
        } finally { $base.Dispose() }
        if ($account) { Remove-LocalUser -SID $account.SID }
        Require (-not (Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue) -and
            @(Get-CimInstance Win32_UserProfile -Filter ("SID='" + $script:AccountSid + "'")).Count -eq 0 -and
            (-not $script:ProfilePath -or -not (Test-Path -LiteralPath $script:ProfilePath))) 'B account, profile and all B data roots were removed' $script:AccountSid
        $remaining = Get-Item -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\' + $markerPath) -ErrorAction SilentlyContinue
        Require (-not $remaining -or @($remaining.GetValueNames() | Where-Object {
            $remaining.GetValue($_, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq $script:AccountSid
        }).Count -eq 0) 'B root marker values were removed' $script:AccountSid
        if ($script:TimerTaskName) { Require (@(Get-ScheduledTask -TaskName $script:TimerTaskName -TaskPath '\' -ErrorAction SilentlyContinue).Count -eq 0) 'B timer task is absent after fixture cleanup' $script:TimerTaskName }
    }

    Save-Result
    $migrationSource = Join-Path $PSScriptRoot 'Test-UpgradeMigration.ps1'
    foreach ($name in 'Quote-Literal', 'Expected-TimerStartup') {
        $helperSource = if ($name -ceq 'Quote-Literal') { Join-Path $PSScriptRoot 'LauncherChecks.Common.ps1' } else { $migrationSource }
        $tokens = $null; $parseErrors = $null
        $helperAst = [Management.Automation.Language.Parser]::ParseFile($helperSource, [ref]$tokens, [ref]$parseErrors)
        Require ($parseErrors.Count -eq 0) 'the migration expected-bytes helper source parses' $helperSource
        $definition = @($helperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | Where-Object Name -ceq $name)
        Require ($definition.Count -eq 1) ('the exact migration ' + $name + ' helper is available')
        . ([scriptblock]::Create($definition[0].Extent.Text))
        Save-Json ('helper-' + $name + '.json') ([ordered]@{source=$helperSource;sourceSha256=(Get-FileHash -LiteralPath $helperSource).Hash;bodySha256=(Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($definition[0].Extent.Text)))})
    }
    Require ([Diagnostics.Process]::GetCurrentProcess().SessionId -gt 0) 'the runner has an interactive main-account desktop'
    Require ($install -ieq 'C:\Program Files\Roo Industries\Optimization Suite') 'the scenario uses the normal installed Program Files path' $install
    foreach ($entry in @(
        @{name='released 0.9';path=$OldInstaller;hash='94C63DE7F717B385EE51D279E08FAAF5CA13F4EA1332EA58F4299C3E31D1FE4B'},
        @{name='ce2305c reproduction';path=$CurrentInstaller;hash='C956F4ECA74DEE873A56B35874069AA4B4B4967BB629C8944F1512980112552E'},
        @{name='fixed build';path=$NewInstaller;hash=$NewInstallerSha256.ToUpperInvariant()}
    )) {
        Require ((Get-FileHash -LiteralPath $entry.path).Hash -ceq $entry.hash) ($entry.name + ' installer has its exact expected SHA256') ($entry.path + ' SHA256=' + $entry.hash)
    }
    Require ($NewInstallerSha256 -ine 'C956F4ECA74DEE873A56B35874069AA4B4B4967BB629C8944F1512980112552E' -and
        $NewInstallerSha256 -ine '94C63DE7F717B385EE51D279E08FAAF5CA13F4EA1332EA58F4299C3E31D1FE4B') 'the fixed installer differs from both earlier installers'
    $script:BeforeAudit = Independent-Audit
    Save-Json 'as-found-before.json' $script:BeforeAudit
    Require ($script:BeforeAudit.state.kind -ceq 'Binary' -and $script:BeforeAudit.state.length -eq 7529986 -and
        $script:BeforeAudit.state.sha256 -ceq '3E83144CD3269C9000E8F36F935CE9FBEE4CABDC0E1F929E347DEA12E5ED924F' -and
        $script:BeforeAudit.dataRows.Count -eq 349 -and $script:BeforeAudit.tasks.Count -eq 6 -and
        -not $script:BeforeAudit.appFolder -and $script:BeforeAudit.uninstall.Count -eq 0 -and
        $script:BeforeAudit.productTasks.Count -eq 0 -and $script:BeforeAudit.productProcesses.Count -eq 0) 'the exact 9070 as-found baseline is present before any install' 'State=7529986/3E83144C; rows=349; CS2 tasks=6; no app/tasks/processes'
    Run-Runner 'preflight' 'preflight' | Out-Null
    $script:RecoveryOpened = $true
    $script:CurrentStage = 'create-B'
    Require (-not (Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue)) 'the temporary account name does not exist'
    $random = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $script:Password = ConvertTo-SecureString ('R!a9' + [Convert]::ToBase64String($random)) -AsPlainText -Force
    [Array]::Clear($random, 0, $random.Length)
    $created = New-LocalUser -Name $accountName -Password $script:Password -AccountNeverExpires -PasswordNeverExpires
    $script:AccountCreated = $true
    $script:AccountSid = $created.SID.Value
    $script:TimerTaskName = 'RooIndustries.Timer.' + (Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($script:AccountSid))).Substring(0, 16)
    Save-Json 'created-account.json' ([ordered]@{name=$accountName;sid=$script:AccountSid;taskName=$script:TimerTaskName;password='generated on this PC and kept only in memory'})
    Add-LocalGroupMember -SID ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) -Member $created
    Require (@(Get-LocalGroupMember -SID ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) | Where-Object { $_.SID.Value -ceq $script:AccountSid }).Count -eq 1) 'B belongs to local Administrators' $script:AccountSid
    foreach ($target in @(@{handle=[SecondAccountNative]::Station();mask=0xF037F}, @{handle=[SecondAccountNative]::Desktop();mask=0xF01FF})) {
        $script:DesktopGrants += [SecondAccountNative]::Grant($target.handle, $script:AccountSid, $target.mask)
        Save-Json 'desktop-grants.json' @($script:DesktopGrants | ForEach-Object {
            [ordered]@{before=[Convert]::ToBase64String($_.before);applied=[Convert]::ToBase64String($_.applied)}
        })
    }
    $holderCommand = '[Threading.Thread]::Sleep(7200000)'
    $holder = Start-Secondary 'B-profile-holder' $powershell @('-NoProfile', '-NonInteractive', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderCommand)))) -Logon
    $script:FullToken = [SecondAccountNative]::FullToken($holder.handle, $script:AccountSid)
    $environment = [SecondAccountNative]::EnvironmentFor($script:FullToken)
    $profile = Get-CimInstance Win32_UserProfile -Filter ("SID='" + $script:AccountSid + "'")
    $script:ProfilePath = [string]$environment['USERPROFILE']
    $script:LocalPath = [string]$environment['LOCALAPPDATA']
    Require ($profile -and $profile.Loaded -and $profile.LocalPath -ieq $script:ProfilePath -and
        $script:LocalPath.StartsWith(($script:ProfilePath + '\'), [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $script:AccountSid))) 'LOGON_WITH_PROFILE loaded the exact B profile and hive' ($script:ProfilePath + ' :: ' + $script:LocalPath)
    Save-Json 'B-profile.json' ([ordered]@{sid=$script:AccountSid;profile=$script:ProfilePath;localAppData=$script:LocalPath;loaded=$profile.Loaded})

    $script:CurrentStage = '0.9-B-timer-on'
    Run-Runner 'install-old' 'install-old' @{OldInstaller=$OldInstaller} | Out-Null
    $previewPath = Join-Path $OutDir 'B-0.9-preview.json'
    $preview = Run-OldHost 'tweak-preview' @{
        profileId='roo-industries-migration-timer'
        selections=@(@{settingId='windows.e9d78835a38cf818';optionId='choice-88665aca77848447'})
        outputPath=$previewPath
    }
    Require ($preview.context.owner.userSid -ceq $script:AccountSid -and
        $preview.selections.Count -eq 1 -and $preview.selections[0].settingId -ceq 'windows.e9d78835a38cf818') '0.9 preview belongs to B and selects only the migration sign-in timer'
    $oldApplyStarted = [DateTime]::UtcNow
    Run-OldHost 'tweak-apply' @{previewPath=$previewPath;reviewHash=(Get-FileHash -LiteralPath $previewPath).Hash;confirm=$true} | Out-Null
    $roots = @('RooOptimizationSuite', 'RooIndustriesOptimizationSuite' | ForEach-Object { Join-Path $script:LocalPath ($_ + '\operations\windows-timer') } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'startup.json') })
    Require ($roots.Count -eq 1) '0.9 created exactly one B timer startup receipt' ($roots -join ',')
    $script:ControlRoot = $roots[0]
    $old = Timer-Evidence 'old-0.9'
    $oldWorker = Capture-TimerWorker 'old-0.9' $oldApplyStarted 'worker'
    Stop-Receipt $oldWorker
    Check $true 'the exact 0.9 B timer worker was stopped before upgrade' ($oldWorker.Identity | ConvertTo-Json -Compress)

    $script:CurrentStage = 'reproduce-C956'
    Run-Runner 'upgrade' 'current-upgrade' @{NewInstaller=$CurrentInstaller} | Out-Null
    $currentBefore = Timer-Evidence 'current-before-app'
    Require ($currentBefore.scriptSha256 -ceq $old.scriptSha256 -and $currentBefore.scriptSha256 -cne $currentBefore.expectedSha256) 'C956 main-account upgrade leaves B script old and stale' ('old=' + $old.scriptSha256 + ' expected=' + $currentBefore.expectedSha256)
    Launch-App 'current-B-app' | Out-Null
    $currentAfter = Timer-Evidence 'current-after-app'
    Require ($currentAfter.scriptSha256 -ceq $old.scriptSha256) 'RC-F2 reproduced: C956 B app leaves the old script after dashboard plus 60 seconds' $currentAfter.scriptSha256

    $script:CurrentStage = 'fixed-B-refresh'
    Run-Runner 'upgrade' 'fixed-upgrade' @{NewInstaller=$NewInstaller} | Out-Null
    $fixedBefore = Timer-Evidence 'fixed-before-app'
    Require ($fixedBefore.scriptSha256 -ceq $old.scriptSha256) 'fixed main-account upgrade still leaves B script old before B app' $fixedBefore.scriptSha256
    $refreshLog = @(Launch-App 'fixed-B-app-first')
    $fixedAfter = Timer-Evidence 'fixed-after-first-app'
    Require (@($refreshLog | Where-Object { $_ -match ('\[timer\] Sign-in start: refreshed: timer startup ' + [regex]::Escape($script:TimerTaskName) + '$') }).Count -ge 1) 'B app.log confirms its exact sign-in startup refresh' 'fixed-B-app-first-new-log-lines.json'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:ControlRoot 'startup.ps1'))) -ceq
        [Convert]::ToBase64String((Expected-TimerStartup $script:ControlRoot))) 'fixed B startup script equals expected installed bytes' $fixedAfter.scriptSha256
    $secondLog = @(Launch-App 'fixed-B-app-second')
    $second = Timer-Evidence 'fixed-after-second-app'
    Require (@($secondLog | Where-Object { $_ -match '\[timer\] Sign-in start: timer startup is current$' }).Count -ge 1) 'second B app launch confirms timer startup is current' 'fixed-B-app-second-new-log-lines.json'
    Require ($second.definitionHash -ceq $fixedAfter.definitionHash -and $second.receiptSha256 -ceq $fixedAfter.receiptSha256 -and
        $second.task.xml -ceq $fixedAfter.task.xml -and $second.task.sddl -ceq $fixedAfter.task.sddl -and
        $second.scriptSha256 -ceq $fixedAfter.scriptSha256) 'second B app launch preserves exact task fingerprint, receipt and script'

    $script:CurrentStage = 'B-autostart'
    $autostartTime = [DateTime]::UtcNow
    $startup = Start-Secondary 'B-startup-script' $powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:ControlRoot 'startup.ps1')) -Logon
    $startupElevated = [SecondAccountNative]::IsElevated($startup.handle)
    Require ($startupElevated -eq $script:ExpectedStartupElevated) 'B startup script elevation matches the recorded EnableLUA' ('EnableLUA=' + $script:EnableLUA + ' expected=' + $script:ExpectedStartupElevated + ' actual=' + $startupElevated)
    $worker = WaitFor { Capture-TimerWorker 'fixed-autostart' $autostartTime 'autostart' } 60 'the installed B --timer-autostart helper to acquire the timer'
    $workerRow = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $worker.Identity.pid)
    $helperElevated = [SecondAccountNative]::IsElevated($worker.handle)
    Require ($workerRow.ParentProcessId -eq $startup.Identity.pid -and $helperElevated -eq $script:ExpectedStartupElevated) 'B helper is the exact startup-script child with elevation matching the recorded EnableLUA' ('EnableLUA=' + $script:EnableLUA + ' expected=' + $script:ExpectedStartupElevated + ' actual=' + $helperElevated + ' parent=' + $workerRow.ParentProcessId + ' startup=' + $startup.Identity.pid)
    Check $true 'B startup hash checks pass and start the exact installed --timer-autostart helper' ($worker.Identity | ConvertTo-Json -Compress)
    Stop-Receipt $worker
    Require ($worker.process.WaitForExit(5000)) 'only the exact owned B autostart helper was stopped'
    if (-not $startup.process.WaitForExit(10000)) { Stop-Receipt $startup }
    Save-Json 'B-startup-script-exit.json' ([ordered]@{identity=$startup.Identity;exit=[SecondAccountNative]::Exit($startup.handle);helper=$worker.Identity})

    $script:CurrentStage = 'uninstall'
    $uninstallEvidence = Run-Runner 'uninstall' 'uninstall'
    $script:Uninstalled = $true
    $uninstallLines = @(Get-Content -LiteralPath (Join-Path $uninstallEvidence 'uninstall.log'))
    Require (@($uninstallLines | Where-Object { $_ -match ('PASS the native uninstall log confirms removed: timer task ' + [regex]::Escape($script:TimerTaskName) + '\b') }).Count -ge 1) 'native uninstall log confirms removal of the exact B timer task' (Join-Path $uninstallEvidence 'uninstall.log')
    $nativeLogs = @(Get-ChildItem -LiteralPath $uninstallEvidence -Recurse -File -Filter 'native-uninstall.log')
    Require ($nativeLogs.Count -eq 1) 'one native uninstall log was retained' $uninstallEvidence
    $nativeLog = [IO.File]::ReadAllText($nativeLogs[0].FullName)
    Require ($nativeLog -match ('(?m)removed: timer task ' + [regex]::Escape($script:TimerTaskName) + '\s*$')) 'native uninstall bytes contain the exact B timer removal line' $nativeLogs[0].FullName
    Save-Json 'B-uninstall-native-log.json' ([ordered]@{path=$nativeLogs[0].FullName;sha256=(Get-FileHash -LiteralPath $nativeLogs[0].FullName).Hash;taskName=$script:TimerTaskName;removed=$true})
    Require (@(Get-ScheduledTask -TaskName $script:TimerTaskName -TaskPath '\' -ErrorAction SilentlyContinue).Count -eq 0) 'uninstall removed B timer task before fixture cleanup' $script:TimerTaskName
} catch {
    Check $false ('scenario stopped in ' + $script:CurrentStage) ($_ | Out-String)
} finally {
    $script:CurrentStage = 'cleanup'
    if ('SecondAccountNative' -as [type]) {
        if ($script:LocalPath) {
            try {
                if (-not $script:ControlRoot) {
                    $partialRoots = @('RooOptimizationSuite', 'RooIndustriesOptimizationSuite' | ForEach-Object {
                        Join-Path $script:LocalPath ($_ + '\operations\windows-timer')
                    } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'session.json') })
                    if ($partialRoots.Count -eq 1) { $script:ControlRoot = $partialRoots[0] }
                }
                if ($script:ControlRoot) {
                    foreach ($sessionPath in @((Join-Path $script:ControlRoot 'session.json'), (Join-Path $script:LocalPath 'RooIndustriesOptimizationSuite.Timer\session.json'))) {
                        if (-not (Test-Path -LiteralPath $sessionPath)) { continue }
                        $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
                        $known = @($script:Processes | Where-Object {
                            $_.Identity.pid -eq $session.processId -and $_.Identity.creationTimeFileTimeUtc -ceq [string]$session.creationTime
                        })
                        if ($known.Count -or -not $session.acquired -or $session.released -or
                            -not (Get-Process -Id $session.processId -ErrorAction SilentlyContinue)) { continue }
                        $kind = if ($sessionPath -ieq (Join-Path $script:ControlRoot 'session.json')) { 'worker' } else { 'autostart' }
                        Capture-TimerWorker ('cleanup-' + $kind) $script:StartedUtc $kind | Out-Null
                    }
                }
            } catch { Check $false 'a partial B timer output could not establish a safe owned process identity' $_.Exception.Message }
        }
        foreach ($path in @(Get-ChildItem -LiteralPath $OutDir -File -Filter 'old-*.host-process.json' -ErrorAction SilentlyContinue)) {
            try {
                if (Test-Path -LiteralPath ($path.FullName -replace '\.host-process\.json$', '.exit')) { continue }
                $identity = Get-Content -LiteralPath $path.FullName -Raw | ConvertFrom-Json
                Stop-OwnedProcessIdentity $identity
            } catch { Check $false 'an exact old Host invocation could not be stopped safely' $_.Exception.Message }
        }
        $ownedProcesses = $script:Processes.ToArray()
        [Array]::Reverse($ownedProcesses)
        foreach ($receipt in $ownedProcesses) {
            try { Stop-Receipt $receipt } catch { Check $false 'an owned process could not be stopped safely' $_.Exception.Message }
        }
        if ($script:FullToken -ne [IntPtr]::Zero) { [SecondAccountNative]::CloseHandle($script:FullToken) | Out-Null; $script:FullToken = [IntPtr]::Zero }
        foreach ($receipt in $script:Processes) {
            try {
                if (-not $receipt.process.HasExited) { throw 'The exact owned process remains live; its profile will not be deleted.' }
                Save-Json ('process-exit-' + $receipt.Identity.pid + '-' + $receipt.Identity.creationTimeFileTimeUtc + '.json') ([ordered]@{identity=$receipt.Identity;exited=$true;exit=$receipt.process.ExitCode})
            } catch { Check $false 'owned process exit evidence was retained' $_.Exception.Message }
            if ($receipt.PSObject.Properties.Name -contains 'native') {
                [SecondAccountNative]::CloseHandle($receipt.native.thread) | Out-Null
                [SecondAccountNative]::CloseHandle($receipt.native.process) | Out-Null
            }
            $receipt.process.Dispose()
        }
        try { Cleanup-Secondary } catch { Check $false 'B fixture cleanup completed without foreign deletion' ($_ | Out-String) }
        for ($i = $script:DesktopGrants.Count - 1; $i -ge 0; $i--) {
            try { [SecondAccountNative]::Restore($script:DesktopGrants[$i]); Check $true 'the owned desktop grant restored its exact original DACL' }
            catch { Check $false 'the owned desktop grant restored its exact original DACL' $_.Exception.Message }
        }
    }
    if ($script:Password) { $script:Password.Dispose(); $script:Password = $null }
    if ($script:RecoveryOpened) {
        try { Run-Runner 'cleanup' 'cleanup' | Out-Null }
        catch { Check $false 'runner cleanup returned the sealed baseline' ($_ | Out-String) }
    }
    if ($script:BeforeAudit) {
        try {
            $after = Independent-Audit
            Save-Json 'as-found-after.json' $after
            $differences = @(foreach ($field in $script:BeforeAudit.Keys) {
                $same = (ConvertTo-Json -InputObject $script:BeforeAudit[$field] -Depth 30 -Compress) -ceq
                    (ConvertTo-Json -InputObject $after[$field] -Depth 30 -Compress)
                Check $same ('independent as-found ' + $field + ' is exactly unchanged')
                if (-not $same) { [ordered]@{field=$field;before=$script:BeforeAudit[$field];after=$after[$field]} }
            })
            Save-Json 'as-found-differences.json' $differences
        } catch { Check $false 'independent final as-found audit completed' ($_ | Out-String) }
    }
    $script:CurrentStage = 'complete'
    foreach ($receipt in $script:Processes) { $receipt.process.Dispose() }
    Save-Result
    Log ('RESULT failures=' + $script:Failures)
    [IO.File]::WriteAllText((Join-Path $OutDir 'second-account-timer-refresh.done'), ('failures=' + $script:Failures))
}
if ($script:Failures) { exit 1 }
