param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[string]$EvidencePath='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-policy-worker-'+[Guid]::NewGuid().ToString('N'))
$hostDirectory=Join-Path $root 'host'
$probeDirectory=Join-Path $root 'probe'
$policyParent=Join-Path $root 'rules parent'
$policyRoot=Join-Path $policyParent 'saved rules'
$limitedOutput=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-limited-'+[Guid]::NewGuid().ToString('N')+'.json')
$probes=New-Object System.Collections.Generic.List[Diagnostics.Process]
$taskName=$null;$limitedTask=$null;$moved=$null
$legacyRoot=Join-Path $root 'legacy rules\process-rules'
$evidence=[ordered]@{startedAtUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;checks=New-Object System.Collections.Generic.List[object];measurements=[ordered]@{}}
function Assert([bool]$Condition,[string]$Message){
    $evidence.checks.Add([pscustomobject]@{passed=$Condition;check=$Message;atUtc=[DateTime]::UtcNow.ToString('o')})
    if(-not $Condition){throw ('FAIL '+$Message)}
    Write-Output ('PASS '+$Message)
}
function Note([string]$Name,$Value){$evidence.measurements[$Name]=$Value;Write-Output ('MEASURE '+$Name+' = '+($Value|ConvertTo-Json -Compress -Depth 6))}
function Worker([string]$WorkerAction,[string]$Root=$policyRoot){
    $text=@(& (Join-Path $PSScriptRoot 'Invoke-ProcessPolicyWorker.ps1') -Action $WorkerAction -PolicyRoot $Root -DotNetPath $DotNetPath -HostDirectory $hostDirectory -ConfirmApply) -join "`n"
    $result=$text|ConvertFrom-Json
    if($result.status -ne 'completed'){throw ('Governor '+$WorkerAction+' failed: '+(@($result.errors|ForEach-Object {$_.message}) -join '; '))}
    return $result.data
}
function Core([string]$CoreAction,[hashtable]$Values=@{},[string]$Root=$policyRoot){
    $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$Root;confirm=$true}
    foreach($key in $Values.Keys){$request[$key]=$Values[$key]}
    $path=Join-Path $root ('request-'+[Guid]::NewGuid().ToString('N')+'.json')
    Write-RooIndustriesOperationJson $request $path
    try {$result=(@(& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $CoreAction $path) -join "`n")|ConvertFrom-Json}
    finally {Remove-Item -LiteralPath $path -Force}
    if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw $result.error.message}
    return $result.data
}
function Start-Probe {
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe'),'3600')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    $probes.Add($process)
    return $process
}
function Wait-Until([scriptblock]$Condition,[double]$Seconds,[int]$PollMilliseconds=50){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not (& $Condition)){if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null};Start-Sleep -Milliseconds $PollMilliseconds}
    return $clock.Elapsed.TotalSeconds
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesGovernorOracle {
    [StructLayout(LayoutKind.Sequential)] struct Throttling { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr process, int kind, out uint value, uint size);
    [DllImport("kernel32.dll", SetLastError=true, EntryPoint="GetProcessInformation")] static extern bool GetThrottling(IntPtr process, int kind, ref Throttling value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr process, int kind, ref uint value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessPriorityBoost(IntPtr process, out bool disabled);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process, uint[] ids, uint count, out uint required);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, out int value, int size, IntPtr length);
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    public static uint Memory(IntPtr p) { uint v; if(!GetProcessInformation(p,0,out v,4)) throw new System.ComponentModel.Win32Exception(); return v; }
    public static void SetMemory(IntPtr p, uint v) { if(!SetProcessInformation(p,0,ref v,4)) throw new System.ComponentModel.Win32Exception(); }
    public static string Qos(IntPtr p) { var t=new Throttling{Version=1}; if(!GetThrottling(p,4,ref t,12)) throw new System.ComponentModel.Win32Exception(); return (t.ControlMask&1)==0?"systemManaged":(t.StateMask&1)!=0?"eco":"high"; }
    public static bool BoostDisabled(IntPtr p) { bool d; if(!GetProcessPriorityBoost(p,out d)) throw new System.ComponentModel.Win32Exception(); return d; }
    public static string CpuSets(IntPtr p) { uint n; GetProcessDefaultCpuSets(p,null,0,out n); var ids=new uint[n]; if(n>0 && !GetProcessDefaultCpuSets(p,ids,n,out n)) throw new System.ComponentModel.Win32Exception(); return string.Join(",",ids); }
    public static int Io(IntPtr p) { int v; int s=NtQueryInformationProcess(p,33,out v,4,IntPtr.Zero); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
    public static int Gpu(IntPtr p) { int v; int s=D3DKMTGetProcessSchedulingPriorityClass(p,out v); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
}
'@
function Read-Controls([Diagnostics.Process]$Process){
    $Process.Refresh()
    return [ordered]@{cpuPriority=[string]$Process.PriorityClass;affinity=('0x{0:X}' -f [int64]$Process.ProcessorAffinity);cpuSets=[RooIndustriesGovernorOracle]::CpuSets($Process.Handle)
        ioPriority=[RooIndustriesGovernorOracle]::Io($Process.Handle);gpuPriority=[RooIndustriesGovernorOracle]::Gpu($Process.Handle);memoryPriority=[RooIndustriesGovernorOracle]::Memory($Process.Handle)
        executionQoS=[RooIndustriesGovernorOracle]::Qos($Process.Handle);priorityBoostDisabled=[RooIndustriesGovernorOracle]::BoostDisabled($Process.Handle)}
}
function Same($Left,$Right){return (($Left|ConvertTo-Json -Compress) -eq ($Right|ConvertTo-Json -Compress))}
function Get-WorkerIdentity{$status=Core 'policy-status';if($status.hostRunning -eq $true){return $status.state.host};return $null}
function Invoke-Limited([string]$Script){
    $scriptPath=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-limited-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    [IO.File]::WriteAllText($scriptPath,$Script,[Text.UTF8Encoding]::new($true))
    Remove-Item -LiteralPath $limitedOutput -Force -ErrorAction SilentlyContinue
    $script:limitedTask='RooIndustriesGovernorLimitedProbe-'+[Guid]::NewGuid().ToString('N')
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$scriptPath+'"')
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:limitedTask -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null
    try {
        Start-ScheduledTask -TaskName $script:limitedTask
        if($null -eq (Wait-Until {Test-Path -LiteralPath $limitedOutput} 60)){throw 'The non-elevated probe did not report.'}
        Start-Sleep -Milliseconds 300
        return (Get-Content -LiteralPath $limitedOutput -Raw -Encoding UTF8|ConvertFrom-Json)
    } finally {
        Unregister-ScheduledTask -TaskName $script:limitedTask -Confirm:$false -ErrorAction SilentlyContinue
        $script:limitedTask=$null
        Remove-Item -LiteralPath $scriptPath,$limitedOutput -Force -ErrorAction SilentlyContinue
    }
}

try {
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $hostDirectory | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Policy host publish failed.'}
    [IO.Directory]::CreateDirectory($probeDirectory)|Out-Null
    Add-Type -TypeDefinition 'public static class RooIndustriesGovernorProbe { public static void Main(string[] args) { System.Threading.Thread.Sleep(System.TimeSpan.FromSeconds(args.Length > 0 ? int.Parse(args[0]) : 600)); } }' -OutputAssembly (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -OutputType ConsoleApplication
    Assert (@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count -eq 0) 'The desktop app is not running during governor validation'

    $first=Start-Probe
    $original=Read-Controls $first
    $snapshot=Core 'process-status' @{processId=$first.Id}
    $topology=@($snapshot.topology|Sort-Object group,index)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$topologyHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($topology|ForEach-Object {''+$_.group+':'+$_.index+':'+$_.core+':'+$_.cache+':'+$_.numa+':'+$_.efficiency}) -join ';'))))).Replace('-','')}
    finally {$sha.Dispose()}
    $cpu=@($topology|Where-Object {$_.available -and $_.group -eq 0})[1]
    $gpu=if($original.gpuPriority -eq 1){2}else{1}
    $wanted=[ordered]@{cpuPriority='AboveNormal';affinity='0x3';cpuSets=[string]$cpu.id;ioPriority=1;gpuPriority=$gpu;memoryPriority=3;executionQoS='eco';priorityBoostDisabled=$true}
    Note 'originalControls' $original
    Note 'requestedControls' $wanted
    Assert (-not (Same $original $wanted) -and $original.cpuPriority -ne 'AboveNormal' -and $original.ioPriority -ne 1 -and $original.memoryPriority -ne 3 -and $original.executionQoS -ne 'eco' -and -not $original.priorityBoostDisabled -and $original.affinity -ne '0x3' -and $original.cpuSets -eq '') 'Every requested control differs from the fresh process default'
    $rule=@{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=(Get-RooIndustriesOperationOwner);name='Disposable governor validation';enabled=$true
        matchMode='path';executablePath=$first.MainModule.FileName;executableHash=$null;affinityTopologyHash=$topologyHash
        controls=@{cpuPriority='AboveNormal';affinity=@{group=0;mask='0x3'};ioPriority=1;gpuPriority=$gpu;memoryPriority=3;executionQoS=@{controlMask=1;stateMask=1};priorityBoost=$false}
        cpuSelection=@{kind='logical';topologyHash=$topologyHash;processors=@(@{group=0;index=[int]$cpu.index});oneThreadPerCore=$false}}

    # (a) saving the first rule starts the governor and a new matching process gets all 8 controls
    Assert (-not (Test-Path -LiteralPath $policyRoot)) 'No rules folder exists before the first rule'
    Core 'rule-save' @{rule=$rule}|Out-Null
    $synced=Worker 'Sync';$taskName=$synced.taskName
    $task=Get-ScheduledTask -TaskName $taskName
    $logon=@($task.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'})
    $triggerUser=[string]$logon[0].UserId
    $triggerSid=if($triggerUser -match '^S-1-'){$triggerUser}else{[Security.Principal.NTAccount]::new($triggerUser).Translate([Security.Principal.SecurityIdentifier]).Value}
    Note 'task' ([ordered]@{name=$taskName;state=[string]$task.State;runLevel=[string]$task.Principal.RunLevel;logonType=[string]$task.Principal.LogonType;multipleInstances=[string]$task.Settings.MultipleInstances;executionTimeLimit=$task.Settings.ExecutionTimeLimit;triggers=@($task.Triggers|ForEach-Object {[ordered]@{kind=$_.CimClass.CimClassName;start=$_.StartBoundary;interval=$_.Repetition.Interval;duration=$_.Repetition.Duration;user=$_.UserId}});action=($task.Actions[0].Execute+' '+$task.Actions[0].Arguments)})
    Assert ($synced.worker.hostRunning -eq $true -and $synced.registered -and $synced.enabled -and $synced.runAtLogon -and $synced.restartEveryMinute -and $synced.secured) 'Saving the first rule registers, secures and starts the governor with sign-in and one-minute restart triggers'
    Assert ($triggerSid -eq (Get-RooIndustriesOperationOwner).userSid -and [string]$task.Principal.RunLevel -eq 'Highest' -and $task.Settings.ExecutionTimeLimit -eq 'PT0S' -and [string]$task.Settings.MultipleInstances -eq 'IgnoreNew' -and $task.Settings.Priority -eq 6) 'The governor task is bound to this user, elevated, unlimited, single-instance and normal priority'
    Assert ($task.Actions[0].Execute -like '*\conhost.exe' -and $task.Actions[0].Arguments -like '--headless *' -and $task.Actions[0].Arguments -like ('*policy-run "'+(Join-Path $policyRoot 'worker-request.json')+'"')) 'The governor runs without a console window and receives its protected request path as one exact argument'
    $worker=Get-CimInstance Win32_Process -Filter ('ProcessId='+$synced.worker.state.host.processId)
    $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$worker.ParentProcessId)
    Note 'workerProcess' ([ordered]@{name=$worker.Name;commandLine=$worker.CommandLine;parent=$parent.Name;parentCommandLine=$parent.CommandLine;session=$worker.SessionId})
    Assert ($parent.Name -eq 'conhost.exe' -and $parent.CommandLine -like '*--headless*') 'The running governor is hosted by a headless console'
    $existingSeconds=Wait-Until {Same (Read-Controls $first) $wanted} 10
    Assert ($null -ne $existingSeconds) 'The governor applies all 8 controls to an already running matching process'
    $second=Start-Probe
    $newSeconds=Wait-Until {Same (Read-Controls $second) $wanted} 10
    Note 'newProcessSecondsToAllEightControls' $newSeconds
    Assert ($null -ne $newSeconds) 'A newly started matching process receives CPU priority, affinity, CPU Sets, I/O, GPU, memory, power mode and boost controls'
    Assert ($newSeconds -le 1.5) ('A new matching process gets its rules within about a second ('+[Math]::Round($newSeconds,2)+' s)')
    Assert (@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count -eq 0) 'Enforcement happened with the desktop app closed'

    $workerIdentity=Get-WorkerIdentity
    $workerProcess=Get-Process -Id $workerIdentity.processId
    Start-Sleep -Seconds 5
    $workerProcess.Refresh();$cpuBefore=$workerProcess.TotalProcessorTime;$clock=[Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 30
    $workerProcess.Refresh();$cpuAfter=$workerProcess.TotalProcessorTime;$elapsed=$clock.Elapsed.TotalSeconds
    Note 'governorIdleFootprint' ([ordered]@{sampleSeconds=[Math]::Round($elapsed,1);cpuPercentOfOneCore=[Math]::Round(100*($cpuAfter-$cpuBefore).TotalSeconds/$elapsed,3);cpuPercentOfMachine=[Math]::Round(100*($cpuAfter-$cpuBefore).TotalSeconds/$elapsed/[Environment]::ProcessorCount,3);privateMegabytes=[Math]::Round($workerProcess.PrivateMemorySize64/1MB,1);workingSetMegabytes=[Math]::Round($workerProcess.WorkingSet64/1MB,1);handles=$workerProcess.HandleCount;threads=$workerProcess.Threads.Count;logicalProcessors=[Environment]::ProcessorCount;watchedProcesses=2})

    # (d) a non-elevated process of the same user cannot change the rules or swap the folder
    $ruleFile=Join-Path $policyRoot ('rules\'+$rule.ruleId+'.json')
    $limited=Invoke-Limited (@'
$ErrorActionPreference='Stop'
$result=[ordered]@{}
$result.elevated=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$result.user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Attempt([scriptblock]$Block){try{& $Block|Out-Null;'allowed'}catch{'denied: '+$_.Exception.Message}}
$result.readRule=Attempt {[IO.File]::ReadAllText('RULE')}
$result.createRule=Attempt {[IO.File]::WriteAllText('ROOT\rules\planted.json','{}')}
$result.modifyRule=Attempt {[IO.File]::AppendAllText('RULE',' ')}
$result.deleteRule=Attempt {[IO.File]::Delete('RULE')}
$result.createControlFile=Attempt {[IO.File]::WriteAllText('ROOT\governor.json','{"schemaVersion":1,"paused":false}')}
$result.replaceRequest=Attempt {[IO.File]::WriteAllText('ROOT\worker-request.json','{}')}
$result.changePermissions=Attempt {$acl=Get-Acl -LiteralPath 'ROOT\rules';$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($result.user,'FullControl','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath 'ROOT\rules' -AclObject $acl}
$result.renameRoot=Attempt {[IO.Directory]::Move('ROOT','ROOT.moved')}
$result.renameParent=Attempt {[IO.Directory]::Move('PARENT','PARENT.moved')}
$result|ConvertTo-Json|Set-Content -LiteralPath 'OUT' -Encoding UTF8
'@).Replace('RULE',$ruleFile).Replace('ROOT',$policyRoot).Replace('PARENT',$policyParent).Replace('OUT',$limitedOutput)
    Note 'nonElevatedAttemptsWhileRunning' $limited
    Assert ($limited.elevated -eq $false -and $limited.user -eq (Get-RooIndustriesOperationOwner).userSid -and $limited.readRule -eq 'allowed') 'The probe ran as the same user without elevation and can read the rules'
    Assert ((@('createRule','modifyRule','deleteRule','createControlFile','replaceRequest','changePermissions','renameRoot','renameParent')|Where-Object {([string]$limited.$_) -notlike 'denied*'}).Count -eq 0) 'A non-elevated process cannot create, change, delete or re-permission rules and control files, or swap the rules folder while the governor runs'
    Assert ((Test-Path -LiteralPath $ruleFile) -and -not (Test-Path -LiteralPath (Join-Path $policyRoot 'rules\planted.json')) -and (Test-Path -LiteralPath $policyParent)) 'The rules folder is unchanged after the denied attempts'

    # (b) killing the governor: it restarts on its own, reconciles journals and keeps undo working
    $firstInstance=@((Core 'policy-status').state.instances|Where-Object {$_.process.processId -eq $first.Id -and $_.status -eq 'active'})
    Assert ($firstInstance.Count -eq 1) 'The running process has one active journal before the crash'
    $killedAt=[DateTime]::UtcNow
    $workerProcess=Get-Process -Id $workerIdentity.processId
    Assert ($workerProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $workerIdentity.creationTimeFileTimeUtc) 'The crash test targets the exact governor instance'
    Stop-Process -Id $workerIdentity.processId -Force
    $workerProcess.WaitForExit()
    $dead=Core 'policy-status'
    Assert ($dead.hostRunning -eq $false -and $dead.state.status -eq 'running') 'A killed governor is reported as not running even though its last record says running'
    Add-Type -AssemblyName System.Web.Extensions
    $serializer=[Web.Script.Serialization.JavaScriptSerializer]::new()
    $journal=$serializer.DeserializeObject([IO.File]::ReadAllText($firstInstance[0].journalPath))
    $journal['status']='applying'
    foreach($change in $journal['changes']){if($change['name'] -eq 'memoryPriority'){$change['status']='applyIntent'}}
    [IO.File]::WriteAllText($firstInstance[0].journalPath,$serializer.Serialize($journal),[Text.UTF8Encoding]::new($false))
    [RooIndustriesGovernorOracle]::SetMemory($first.Handle,$original.memoryPriority)
    $restartSeconds=Wait-Until {$identity=Get-WorkerIdentity;$null -ne $identity -and $identity.processId -ne $workerIdentity.processId} 150 1000
    Note 'restartSecondsAfterKill' $restartSeconds
    Assert ($null -ne $restartSeconds -and $restartSeconds -le 125) 'The scheduled task restarts a killed governor within about two minutes without the app'
    $reconciled=Wait-Until {Same (Read-Controls $first) $wanted} 10
    $after=@((Core 'policy-status').state.instances|Where-Object {$_.process.processId -eq $first.Id -and $_.status -notin @('restored','expired')})
    Assert ($null -ne $reconciled -and $after.Count -eq 1 -and $after[0].journalPath -eq $firstInstance[0].journalPath -and $after[0].status -eq 'active' -and (Read-RooIndustriesOperationJson $after[0].journalPath).data.status -eq 'applied') 'The restarted governor reconciles the crashed journal, finishes the interrupted write and keeps the same recovery record'
    $third=Start-Probe
    Assert ($null -ne (Wait-Until {Same (Read-Controls $third) $wanted} 10)) 'A process started after the restart gets its rules'

    # (c) pause restores and stays paused
    $paused=Worker 'Pause'
    $restored=Wait-Until {(Same (Read-Controls $first) $original) -and (Same (Read-Controls $second) $original) -and (Same (Read-Controls $third) $original)} 5
    Assert ($paused.paused -and -not $paused.enabled -and $paused.worker.hostRunning -eq $false -and $null -ne $restored) 'Pause stops the governor, disables its task and restores all 8 controls on every running process'
    Assert (@((Core 'policy-status').state.instances|Where-Object {$_.status -notin @('restored','expired')}).Count -eq 0) 'Every journal is restored after pause'
    Start-Sleep -Seconds 75
    $stillPaused=Worker 'Status'
    Assert ($stillPaused.worker.hostRunning -eq $false -and $stillPaused.paused -and (Same (Read-Controls $first) $original)) 'A paused governor is not restarted by its one-minute trigger'

    # (d, continued) a folder planted by a non-elevated process while paused is refused, never adopted
    $limited=Invoke-Limited (@'
$ErrorActionPreference='Stop'
$result=[ordered]@{}
try {[IO.Directory]::Move('ROOT','ROOT.moved');[IO.Directory]::CreateDirectory('ROOT\rules')|Out-Null;[IO.File]::WriteAllText('ROOT\rules\RULEID.json',[IO.File]::ReadAllText('ROOT.moved\rules\RULEID.json').Replace('"AboveNormal"','"High"'));[IO.File]::Copy('ROOT.moved\worker-request.json','ROOT\worker-request.json');$result.planted='yes'} catch {$result.planted='no: '+$_.Exception.Message}
$result|ConvertTo-Json|Set-Content -LiteralPath 'OUT' -Encoding UTF8
'@).Replace('ROOT',$policyRoot).Replace('RULEID',$rule.ruleId).Replace('OUT',$limitedOutput)
    Note 'nonElevatedPlantWhilePaused' $limited
    if($limited.planted -eq 'yes'){
        $moved=$policyRoot+'.moved'
        $summary=Core 'policy-summary'
        $refusedSync=$null;try {Worker 'Resume'|Out-Null} catch {$refusedSync=$_.Exception.Message}
        $refusedRun=$null;try {& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') policy-run (Join-Path $policyRoot 'worker-request.json')|Out-Null;if($LASTEXITCODE -ne 0){$refusedRun='exit '+$LASTEXITCODE}} catch {$refusedRun=$_.Exception.Message}
        Note 'plantedFolderRefusals' ([ordered]@{secured=$summary.secured;problem=$summary.securityProblem;sync=$refusedSync;run=$refusedRun})
        Assert (-not $summary.secured -and $refusedSync -like '*administrator rights*' -and $null -ne $refusedRun -and (Same (Read-Controls $first) $original)) 'A rules folder planted without elevation is reported unprotected, never migrated and never run'
        Remove-Item -LiteralPath $policyRoot -Recurse -Force
        [IO.Directory]::Move($moved,$policyRoot);$moved=$null
    } else {
        Assert ($limited.planted -like 'no:*') 'The rules folder could not be swapped by a non-elevated process while paused'
    }

    $resumed=Worker 'Resume'
    Assert ($resumed.worker.hostRunning -eq $true -and $resumed.enabled -and -not $resumed.paused -and $null -ne (Wait-Until {(Same (Read-Controls $first) $wanted) -and (Same (Read-Controls $third) $wanted)} 10)) 'Start governor enables the task and re-applies the rules'

    # Apply once refuses a field the governor owns
    $previewPath=Join-Path $root 'direct-preview.json'
    Core 'process-preview' @{processId=$first.Id;controls=@{memoryPriority=4};outputPath=$previewPath}|Out-Null
    $directError=$null
    try {Core 'process-apply' @{previewPath=$previewPath;reviewHash=(Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash;journalPath=(Join-Path $root 'direct-journal.json')}|Out-Null} catch {$directError=$_.Exception.Message}
    Assert ($directError -like 'Managed by the governor*' -and [RooIndustriesGovernorOracle]::Memory($first.Handle) -eq 3) 'Apply once refuses a process field that the governor owns'

    # bounded history: many short-lived processes leave at most 50 finished records and no orphan folders
    for($index=0;$index -lt 55;$index++){
        $short=Start-Probe
        if($null -eq (Wait-Until {[RooIndustriesGovernorOracle]::Memory($short.Handle) -eq 3} 5)){throw 'A short-lived process did not get its rule.'}
        $short.Kill();$short.WaitForExit()
    }
    $bounded=Wait-Until {$instances=@((Core 'policy-status').state.instances);@($instances|Where-Object {$_.status -notin @('restored','expired')}).Count -le 3 -and @($instances|Where-Object {$_.status -in @('restored','expired')}).Count -eq 50} 20 500
    $instances=@((Core 'policy-status').state.instances)
    $folders=@(Get-ChildItem -LiteralPath (Join-Path $policyRoot 'operations') -Directory)
    Note 'historyAfter55ShortProcesses' ([ordered]@{instances=$instances.Count;finished=@($instances|Where-Object {$_.status -in @('restored','expired')}).Count;operationFolders=$folders.Count})
    Assert ($null -ne $bounded -and $folders.Count -eq $instances.Count) 'After 55 short-lived processes the governor keeps exactly 50 finished records and deletes the pruned operation folders'

    # (e) deleting the last rule stops the governor, removes the task and restores values
    Core 'rule-delete' @{ruleId=$rule.ruleId}|Out-Null
    $removed=Worker 'Sync'
    Assert (-not $removed.registered -and $removed.worker.hostRunning -eq $false -and -not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) 'Deleting the last rule stops the governor and removes its task and triggers'
    Assert ((Same (Read-Controls $first) $original) -and (Same (Read-Controls $third) $original)) 'Deleting the last rule restores every running process'
    # migration of a folder written by the earlier version: user-owned files are refused, a clean folder moves byte for byte, an interrupted swap is adopted
    [IO.Directory]::CreateDirectory((Join-Path $legacyRoot 'rules'))|Out-Null
    $legacyRule=$rule.Clone();$legacyRule.ruleId=[Guid]::NewGuid().ToString('N');$legacyRule.revision=[Guid]::NewGuid().ToString('N')
    $legacyFile=Join-Path $legacyRoot ('rules\'+$legacyRule.ruleId+'.json')
    Write-RooIndustriesOperationJson $legacyRule $legacyFile
    $legacyHash=(Get-FileHash -LiteralPath $legacyFile).Hash
    $legacyWrite=(@'
try {[IO.File]::WriteAllText('LEGACY\rules\note.txt','x');$r='allowed'} catch {$r='denied: '+$_.Exception.Message}
@{write=$r}|ConvertTo-Json|Set-Content -LiteralPath 'OUT' -Encoding UTF8
'@).Replace('LEGACY',$legacyRoot).Replace('OUT',$limitedOutput)
    $limited=Invoke-Limited $legacyWrite
    Assert ($limited.write -eq 'allowed') 'BEFORE: the earlier unprotected rules folder lets a non-elevated process add files'
    Remove-Item -LiteralPath (Join-Path $legacyRoot 'rules\note.txt') -Force
    $migrated=Worker 'Sync' $legacyRoot
    $legacyAcl=Get-Acl -LiteralPath $legacyRoot
    Note 'migratedAcl' ([ordered]@{owner=$legacyAcl.Owner;protected=$legacyAcl.AreAccessRulesProtected;access=@($legacyAcl.Access|ForEach-Object {''+$_.IdentityReference+':'+$_.FileSystemRights+':'+$_.AccessControlType})})
    Assert ($migrated.secured -and $migrated.worker.hostRunning -eq $true -and (Get-FileHash -LiteralPath $legacyFile).Hash -eq $legacyHash -and $legacyAcl.Owner -eq 'BUILTIN\Administrators' -and $legacyAcl.AreAccessRulesProtected -and @(Get-ChildItem -LiteralPath (Split-Path $legacyRoot -Parent) -Directory -Filter 'process-rules.*').Count -eq 0) 'An earlier folder written by the elevated app is migrated byte for byte into a protected folder and the governor starts'
    Assert ($null -ne (Wait-Until {Same (Read-Controls $first) $wanted} 10)) 'The migrated rule is enforced'
    $limited=Invoke-Limited $legacyWrite
    Assert ($limited.write -like 'denied*') 'AFTER: the migrated folder refuses a non-elevated write'
    Worker 'Pause' $legacyRoot|Out-Null
    $interrupted=$legacyRoot+'.secure-'+[Guid]::NewGuid().ToString('N')
    [IO.Directory]::Move($legacyRoot,$interrupted)
    [IO.File]::WriteAllBytes((Join-Path $interrupted '.migrated'),[byte[]]@())
    Core 'policy-secure' @{} $legacyRoot|Out-Null
    Assert ((Test-Path -LiteralPath $legacyFile) -and (Get-FileHash -LiteralPath $legacyFile).Hash -eq $legacyHash -and -not (Test-Path -LiteralPath $interrupted) -and (Core 'policy-summary' @{} $legacyRoot).secured) 'A migration interrupted between its two renames is completed from the protected copy instead of starting empty'
    Worker 'Remove' $legacyRoot|Out-Null
    Assert (Same (Read-Controls $first) $original) 'Removing the migrated governor restores the process'

    $sessionScript=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-ProtectedGameSession.ps1'),[ref]$null,[ref]$null)
    $sessionSettings=@($sessionScript.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-ScheduledTaskSettingsSet'},$true))
    $sessionPriority=@($sessionSettings|ForEach-Object {$elements=$_.CommandElements;for($i=0;$i -lt $elements.Count-1;$i++){if($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Priority'){$elements[$i+1].Extent.Text}}})
    Assert ($sessionSettings.Count -eq 1 -and $sessionPriority.Count -eq 1 -and $sessionPriority[0] -eq '6') 'The protected-session host task is registered at normal priority'
} finally {
    foreach($name in @($limitedTask)){if($name){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue}}
    if($moved -and (Test-Path -LiteralPath $moved)){if(Test-Path -LiteralPath $policyRoot){Remove-Item -LiteralPath $policyRoot -Recurse -Force};[IO.Directory]::Move($moved,$policyRoot)}
    if(Test-Path -LiteralPath (Join-Path $hostDirectory 'Optimizer.Host.dll')){
        try {Worker 'Remove'|Out-Null} catch {Write-Output ('Cleanup: '+$_.Exception.Message)}
        if(Test-Path -LiteralPath $legacyRoot){try {Worker 'Remove' $legacyRoot|Out-Null} catch {Write-Output ('Cleanup: '+$_.Exception.Message)}}
    }
    if($taskName -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    foreach($probe in $probes){if(-not $probe.HasExited){$probe.Kill()};$probe.WaitForExit();$probe.Dispose()}
    Remove-Item -LiteralPath $limitedOutput -Force -ErrorAction SilentlyContinue
    $markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    if($markers){foreach($name in @($markers.GetValueNames()|Where-Object {$_.StartsWith($root.ToUpperInvariant())})){Remove-ItemProperty -LiteralPath $markers.PSPath -Name $name}}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    $evidence.finishedAtUtc=[DateTime]::UtcNow.ToString('o')
    if($EvidencePath){[IO.File]::WriteAllText($EvidencePath,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
}
Assert (-not(Test-Path -LiteralPath $root) -and ($null -eq $taskName -or -not(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))) 'Governor validation removes its scheduled task, processes and temporary state'
