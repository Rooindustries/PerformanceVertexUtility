$OutputEncoding=[Text.UTF8Encoding]::new($false)

function Assert([bool]$Condition,[string]$Message){
    $script:current.checks.Add([pscustomobject]@{passed=$Condition;check=$Message;atUtc=[DateTime]::UtcNow.ToString('o')})
    if(-not $Condition){throw ('FAIL '+$Message)}
    Write-Output ('PASS '+$Message)
}

function Note([string]$Name,$Value){$script:current.measurements[$Name]=$Value;Write-Output ('MEASURE '+$Name+' = '+($Value|ConvertTo-Json -Compress -Depth 8))}

function Core([string]$CoreAction,[hashtable]$Values=@{},[string]$Folder=$script:policyRoot){
    $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$Folder;confirm=$true}
    foreach($key in $Values.Keys){$request[$key]=$Values[$key]}
    $result=(@(($request|ConvertTo-Json -Depth 32 -Compress)|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $CoreAction '-') -join "`n")|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw $result.error.message}
    return $result.data
}

function Worker([string]$WorkerAction,[string]$Folder=$script:policyRoot){
    $text=@(& (Join-Path $scriptsRoot 'Invoke-ProcessPolicyWorker.ps1') -Action $WorkerAction -PolicyRoot $Folder -DotNetPath $DotNetPath -HostDirectory $hostDirectory -ConfirmApply) -join "`n"
    $result=$text|ConvertFrom-Json
    if($result.status -ne 'completed'){throw ('Governor '+$WorkerAction+' failed: '+(@($result.errors|ForEach-Object {$_.message}) -join '; '))}
    if($result.data.taskName -and $script:tasks -notcontains $result.data.taskName){$script:tasks.Add($result.data.taskName)}
    if($script:roots -notcontains $Folder){$script:roots.Add($Folder)}
    return $result.data
}

function Wait-Until([scriptblock]$Condition,[double]$Seconds,[int]$PollMilliseconds=100){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        $met=$false;try {$met=[bool](& $Condition)} catch {}
        if($met){return $clock.Elapsed.TotalSeconds}
        if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null}
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}

function Same($Left,$Right){return (($Left|ConvertTo-Json -Compress) -eq ($Right|ConvertTo-Json -Compress))}

function Initialize-ScenarioFixtures {
    [Diagnostics.Process]::EnterDebugMode()
    [IO.Directory]::CreateDirectory($probeDirectory)|Out-Null
    Add-Type -TypeDefinition 'public static class RooIndustriesGovernorScenarioProbe { public static void Main(string[] args) { System.Threading.Thread.Sleep(System.TimeSpan.FromSeconds(args.Length > 0 ? int.Parse(args[0]) : 600)); } }' -OutputAssembly (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -OutputType ConsoleApplication
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Security.Principal; using System.Threading;
public static class RooIndustriesGovernorScenarioFixture {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Trustee { public IntPtr Multiple; public int Operation; public int Form; public int Type; public IntPtr Name; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Access { public uint Permissions; public int Mode; public uint Inheritance; public Trustee Trustee; }
    [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(IntPtr handle, int type, int info, IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern uint SetEntriesInAcl(int count, ref Access entries, IntPtr old, out IntPtr acl);
    [DllImport("advapi32.dll")] static extern uint SetSecurityInfo(IntPtr handle, int type, int info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    public static void Main(string[] args) {
        Thread.Sleep(TimeSpan.FromSeconds(int.Parse(args[0])));
        var mask = Convert.ToUInt32(args[1], 16); var lift = int.Parse(args[2]); var life = int.Parse(args[3]);
        var sid = WindowsIdentity.GetCurrent().User; var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        var pointer = Marshal.AllocHGlobal(bytes.Length); Marshal.Copy(bytes, 0, pointer, bytes.Length);
        IntPtr dacl, descriptor, updated;
        if (GetSecurityInfo(GetCurrentProcess(), 6, 4, IntPtr.Zero, IntPtr.Zero, out dacl, IntPtr.Zero, out descriptor) != 0) Environment.Exit(3);
        var entry = new Access { Permissions = mask, Mode = 3, Inheritance = 0, Trustee = new Trustee { Form = 0, Type = 1, Name = pointer } };
        if (SetEntriesInAcl(1, ref entry, dacl, out updated) != 0 || SetSecurityInfo(GetCurrentProcess(), 6, 4, IntPtr.Zero, IntPtr.Zero, updated, IntPtr.Zero) != 0) Environment.Exit(4);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        if (lift > 0) { Thread.Sleep(TimeSpan.FromSeconds(lift)); if (SetSecurityInfo(GetCurrentProcess(), 6, 4, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero) != 0) Environment.Exit(5); }
        var rest = TimeSpan.FromSeconds(life) - watch.Elapsed; if (rest > TimeSpan.Zero) Thread.Sleep(rest);
    }
}
'@ -OutputAssembly (Join-Path $probeDirectory 'RooIndustriesGovernorFixture.exe') -OutputType ConsoleApplication
    if(-not ('RooIndustriesGovernorScenarioOracle' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesGovernorScenarioOracle {
    [StructLayout(LayoutKind.Sequential)] struct Throttling { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr process, int kind, out uint value, uint size);
    [DllImport("kernel32.dll", SetLastError=true, EntryPoint="GetProcessInformation")] static extern bool GetThrottling(IntPtr process, int kind, ref Throttling value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr process, int kind, ref uint value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessPriorityBoost(IntPtr process, out bool disabled);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process, uint[] ids, uint count, out uint required);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, out int value, int size, IntPtr length);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int kind, ref int value, int size);
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr process);
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    public static uint Memory(IntPtr p) { uint v; if(!GetProcessInformation(p,0,out v,4)) throw new System.ComponentModel.Win32Exception(); return v; }
    public static void SetMemory(IntPtr p, uint v) { if(!SetProcessInformation(p,0,ref v,4)) throw new System.ComponentModel.Win32Exception(); }
    public static string Qos(IntPtr p) { var t=new Throttling{Version=1}; if(!GetThrottling(p,4,ref t,12)) throw new System.ComponentModel.Win32Exception(); return (t.ControlMask&1)==0?"systemManaged":(t.StateMask&1)!=0?"eco":"high"; }
    public static bool BoostDisabled(IntPtr p) { bool d; if(!GetProcessPriorityBoost(p,out d)) throw new System.ComponentModel.Win32Exception(); return d; }
    public static string CpuSets(IntPtr p) { uint n; GetProcessDefaultCpuSets(p,null,0,out n); var ids=new uint[n]; if(n>0 && !GetProcessDefaultCpuSets(p,ids,n,out n)) throw new System.ComponentModel.Win32Exception(); return string.Join(",",ids); }
    public static int Io(IntPtr p) { int v; int s=NtQueryInformationProcess(p,33,out v,4,IntPtr.Zero); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
    public static void SetIo(IntPtr p, int v) { int s=NtSetInformationProcess(p,33,ref v,4); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); }
    public static int Gpu(IntPtr p) { int v; int s=D3DKMTGetProcessSchedulingPriorityClass(p,out v); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
    public static void Suspend(IntPtr p) { int s=NtSuspendProcess(p); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); }
    public static void Resume(IntPtr p) { int s=NtResumeProcess(p); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); }
}
'@
    }
}

function Enter-Scenario([string]$Name){
    $script:scenarioRoot=Join-Path $work ($Name+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
    $script:policyParent=Join-Path $script:scenarioRoot 'data'
    $script:policyRoot=Join-Path $script:policyParent 'process-rules'
    $script:probes=New-Object System.Collections.Generic.List[Diagnostics.Process]
    $script:roots=New-Object System.Collections.Generic.List[string]
    $script:tasks=New-Object System.Collections.Generic.List[string]
    $script:cleanups=New-Object System.Collections.Generic.List[scriptblock]
    [IO.Directory]::CreateDirectory($script:policyParent)|Out-Null
}

function Exit-Scenario {
    $problems=New-Object System.Collections.Generic.List[string]
    for($index=$script:cleanups.Count-1;$index -ge 0;$index--){try {& $script:cleanups[$index]} catch {$problems.Add($_.Exception.Message)}}
    foreach($variable in @(Get-ChildItem Env: | Where-Object {$_.Name -like 'ROO_INDUSTRIES_TEST_*'})){Remove-Item -LiteralPath ('Env:\'+$variable.Name)}
    foreach($folder in $script:roots){
        if(Test-Path -LiteralPath (Join-Path $folder 'rules')){try {Worker 'Remove' $folder|Out-Null} catch {$problems.Add('Remove '+$folder+': '+$_.Exception.Message)}}
    }
    foreach($task in $script:tasks){if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $task -Confirm:$false}}
    foreach($probe in $script:probes){try {if(-not $probe.HasExited){$probe.Kill()};$probe.WaitForExit(10000)|Out-Null;$probe.Dispose()} catch {}}
    $leaf=(Split-Path $script:scenarioRoot -Leaf).ToUpperInvariant()
    foreach($process in @(Get-CimInstance Win32_Process|Where-Object {[string]$_.CommandLine -like ('*'+(Split-Path $script:scenarioRoot -Leaf)+'*')})){Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}
    Start-Sleep -Milliseconds 500
    $markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    if($markers){foreach($name in @($markers.GetValueNames()|Where-Object {$_ -like ('*\'+$leaf+'\*')})){Remove-ItemProperty -LiteralPath $markers.PSPath -Name $name}}
    for($attempt=0;$attempt -lt 20 -and (Test-Path -LiteralPath $script:scenarioRoot);$attempt++){
        try {Remove-Item -LiteralPath $script:scenarioRoot -Recurse -Force -ErrorAction Stop} catch {Start-Sleep -Milliseconds 500}
    }
    if(Test-Path -LiteralPath $script:scenarioRoot){$problems.Add('The scenario folder could not be removed: '+$script:scenarioRoot)}
    if($problems.Count -gt 0){throw ($problems -join '; ')}
}

function Copy-Probe([string]$Name='RooIndustriesGovernorProbe.exe',[string]$Folder='probes',[string]$Source='RooIndustriesGovernorProbe.exe'){
    $directory=Join-Path $script:scenarioRoot $Folder
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $path=Join-Path $directory $Name
    Copy-Item -LiteralPath (Join-Path $probeDirectory $Source) -Destination $path -Force
    return $path
}

function Start-Probe([string]$Path,[string]$Arguments='3600',[switch]$NoWait){
    $info=[Diagnostics.ProcessStartInfo]::new($Path,$Arguments)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    $script:probes.Add($process)
    if(-not $NoWait){$null=Wait-Until {$process.Refresh();$null -ne $process.Handle -and $process.PriorityClass} 10}
    return $process
}

function Read-Controls([Diagnostics.Process]$Process){
    $Process.Refresh()
    return [ordered]@{cpuPriority=[string]$Process.PriorityClass;affinity=('0x{0:X}' -f [int64]$Process.ProcessorAffinity);cpuSets=[RooIndustriesGovernorScenarioOracle]::CpuSets($Process.Handle)
        ioPriority=[RooIndustriesGovernorScenarioOracle]::Io($Process.Handle);gpuPriority=[RooIndustriesGovernorScenarioOracle]::Gpu($Process.Handle);memoryPriority=[RooIndustriesGovernorScenarioOracle]::Memory($Process.Handle)
        executionQoS=[RooIndustriesGovernorScenarioOracle]::Qos($Process.Handle);priorityBoostDisabled=[RooIndustriesGovernorScenarioOracle]::BoostDisabled($Process.Handle)}
}

function Read-Field([Diagnostics.Process]$Process,[string]$Field){return (Read-Controls $Process)[$Field]}

function Set-Field([Diagnostics.Process]$Process,[string]$Field,$Value){
    switch($Field){
        'cpuPriority' {$Process.PriorityClass=[Diagnostics.ProcessPriorityClass]$Value}
        'ioPriority' {[RooIndustriesGovernorScenarioOracle]::SetIo($Process.Handle,[int]$Value)}
        'memoryPriority' {[RooIndustriesGovernorScenarioOracle]::SetMemory($Process.Handle,[uint32]$Value)}
        default {throw ('Set-Field does not support '+$Field)}
    }
}

function New-Rule([string]$Path,[hashtable]$Controls,[string]$Name='Scenario rule',[string]$MatchMode='path',$CpuSelection=$null){
    return @{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=(Get-RooIndustriesOperationOwner);name=$Name;enabled=$true
        matchMode=$MatchMode;executablePath=$Path;executableHash=$null;affinityTopologyHash=$null;controls=$Controls;cpuSelection=$CpuSelection}
}

function Get-TopologyChoice([Diagnostics.Process]$Process){
    $snapshot=Core 'process-status' @{processId=$Process.Id}
    $topology=@($snapshot.topology|Sort-Object group,index)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($topology|ForEach-Object {''+$_.group+':'+$_.index+':'+$_.core+':'+$_.cache+':'+$_.numa+':'+$_.efficiency}) -join ';'))))).Replace('-','')}
    finally {$sha.Dispose()}
    $cpu=@($topology|Where-Object {$_.available -and $_.group -eq 0})[1]
    return [pscustomobject]@{topologyHash=$hash;cpu=$cpu;selection=@{kind='logical';topologyHash=$hash;processors=@(@{group=0;index=[int]$cpu.index});oneThreadPerCore=$false}}
}

function Save-Rule($Rule,[string]$Folder=$script:policyRoot){
    if($script:roots -notcontains $Folder){$script:roots.Add($Folder)}
    return Core 'rule-save' @{rule=$Rule} $Folder
}

function Get-GovernorState([string]$Folder=$script:policyRoot){return (Core 'policy-status' @{} $Folder).state}

function Get-Records([int]$ProcessId,[string]$Folder=$script:policyRoot){
    return @((Get-GovernorState $Folder).instances|Where-Object {$_.process.processId -eq $ProcessId})
}

function Get-Open([int]$ProcessId,[string]$Folder=$script:policyRoot){
    return @(Get-Records $ProcessId $Folder|Where-Object {$_.status -notin @('restored','expired')})
}

function Get-Heartbeat([string]$Folder=$script:policyRoot){
    $path=Join-Path $Folder 'heartbeat.json'
    if(-not (Test-Path -LiteralPath $path)){return $null}
    return (Read-RooIndustriesOperationJson $path).data
}

function Get-WorkerProcess([string]$Folder=$script:policyRoot){
    $status=Core 'policy-status' @{} $Folder
    if($status.hostRunning -ne $true){return $null}
    return Get-Process -Id $status.state.host.processId -ErrorAction SilentlyContinue
}

function Start-ManualWorker([string]$Folder=$script:policyRoot){
    $process=Start-Process -FilePath $DotNetPath -ArgumentList ('"'+(Join-Path $hostDirectory 'Optimizer.Host.dll')+'" policy-run "'+(Join-Path $Folder 'worker-request.json')+'"') -WindowStyle Hidden -PassThru
    $script:probes.Add($process)
    return $process
}

function Hold-File([string]$Path,[int]$Milliseconds){
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    return [pscustomobject]@{stream=$stream;until=[DateTime]::UtcNow.AddMilliseconds($Milliseconds)}
}

function Start-Limited([string]$Script){
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $runas=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\runas.exe') -ArgumentList ('/trustlevel:0x20000 "'+(Join-Path $env:SystemRoot 'System32\conhost.exe')+' --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded+'"') -WindowStyle Hidden -PassThru
    return $runas
}

function Start-SystemProcess([string]$Path,[string]$Arguments='600'){
    $task='RooIndustries_GovernorScenarioSystem_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $action=New-ScheduledTaskAction -Execute $Path -Argument $Arguments
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)) -Force|Out-Null
    $script:tasks.Add($task)
    Start-ScheduledTask -TaskName $task
    $found=$null
    $null=Wait-Until {$script:systemProcess=@(Get-CimInstance Win32_Process -Filter ("Name='"+(Split-Path $Path -Leaf)+"'")|Where-Object {$_.ExecutablePath -eq $Path})[0];$null -ne $script:systemProcess} 20 200
    if($null -eq $script:systemProcess){throw 'The SYSTEM probe did not start.'}
    $found=Get-Process -Id $script:systemProcess.ProcessId
    $script:probes.Add($found)
    return $found
}

function Get-ExposedWriters([string]$Path){
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-3-4')
    $writable=[Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete,DeleteSubdirectoriesAndFiles,WriteAttributes,WriteExtendedAttributes,ChangePermissions,TakeOwnership'
    $found=New-Object System.Collections.Generic.List[string]
    $acl=Get-Acl -LiteralPath $Path
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544'){$found.Add($Path+' owner '+$acl.Owner)}
    foreach($rule in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $trusted -notcontains $_.IdentityReference.Value})){
        if(($rule.FileSystemRights -band $writable) -ne 0){$found.Add($Path+' '+$rule.IdentityReference.Value+' '+$rule.FileSystemRights)}
    }
    return @($found)
}
