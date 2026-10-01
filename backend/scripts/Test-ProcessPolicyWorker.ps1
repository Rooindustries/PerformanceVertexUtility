param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[string]$EvidencePath='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-policy-worker-'+[Guid]::NewGuid().ToString('N'))
$hostDirectory=Join-Path $root 'host'
$probeDirectory=Join-Path $root 'probe'
$policyParent=Join-Path $root 'rules parent'
$policyRoot=Join-Path $policyParent 'process-rules'
$limitedOutput=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-limited-'+[Guid]::NewGuid().ToString('N')+'.json')
$probes=New-Object System.Collections.Generic.List[Diagnostics.Process]
$taskName=$null;$moved=$null;$sessionActive=$false;$sessionRoot=$null
$legacyRoot=Join-Path $root 'legacy rules\process-rules'
$evidence=[ordered]@{startedAtUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;checks=New-Object System.Collections.Generic.List[object];measurements=[ordered]@{}}
function Assert([bool]$Condition,[string]$Message){
    $evidence.checks.Add([pscustomobject]@{passed=$Condition;check=$Message;atUtc=[DateTime]::UtcNow.ToString('o')})
    if(-not $Condition){throw ('FAIL '+$Message)}
    Write-Output ('PASS '+$Message)
}
function Note([string]$Name,$Value){$evidence.measurements[$Name]=$Value;Write-Output ('MEASURE '+$Name+' = '+($Value|ConvertTo-Json -Compress -Depth 6))}
function Worker([string]$WorkerAction,[string]$Folder=$policyRoot){
    $text=@(& (Join-Path $PSScriptRoot 'Invoke-ProcessPolicyWorker.ps1') -Action $WorkerAction -PolicyRoot $Folder -DotNetPath $DotNetPath -HostDirectory $hostDirectory -ConfirmApply) -join "`n"
    $result=$text|ConvertFrom-Json
    if($result.status -ne 'completed'){throw ('Governor '+$WorkerAction+' failed: '+(@($result.errors|ForEach-Object {$_.message}) -join '; '))}
    return $result.data
}
$OutputEncoding=[Text.UTF8Encoding]::new($false)
function Core([string]$CoreAction,[hashtable]$Values=@{},[string]$Folder=$policyRoot){
    $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$Folder;confirm=$true}
    foreach($key in $Values.Keys){$request[$key]=$Values[$key]}
    $result=(@(($request|ConvertTo-Json -Depth 32 -Compress)|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $CoreAction '-') -join "`n")|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw $result.error.message}
    return $result.data
}
function Start-Limited([string]$Script){
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $runas=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\runas.exe') -ArgumentList ('/trustlevel:0x20000 "'+(Join-Path $env:SystemRoot 'System32\conhost.exe')+' --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded+'"') -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    if($runas.HasExited -and $runas.ExitCode -ne 0){throw ('runas /trustlevel failed with exit code '+$runas.ExitCode)}
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
    while($true){
        $met=$false;try {$met=[bool](& $Condition)} catch {}
        if($met){break}
        if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null}
        Start-Sleep -Milliseconds $PollMilliseconds
    }
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
    Remove-Item -LiteralPath $limitedOutput -Force -ErrorAction SilentlyContinue
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $runas=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\runas.exe') -ArgumentList ('/trustlevel:0x20000 "'+(Join-Path $env:SystemRoot 'System32\conhost.exe')+' --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded+'"') -WindowStyle Hidden -PassThru -Wait
    if($runas.ExitCode -ne 0){throw ('runas /trustlevel failed with exit code '+$runas.ExitCode)}
    try {
        if($null -eq (Wait-Until {Test-Path -LiteralPath $limitedOutput} 60)){throw 'The non-elevated probe did not report.'}
        Start-Sleep -Milliseconds 300
        return (Get-Content -LiteralPath $limitedOutput -Raw -Encoding UTF8|ConvertFrom-Json)
    } finally {Remove-Item -LiteralPath $limitedOutput -Force -ErrorAction SilentlyContinue}
}

try {
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -p:GovernorTestHooks=true -o $hostDirectory | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Policy host publish failed.'}
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.SessionHost\Optimizer.SessionHost.csproj') -c Release -r win-x64 --self-contained true -p:GovernorTestHooks=true -o (Join-Path $hostDirectory 'session') | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Session host publish failed.'}
    [IO.Directory]::CreateDirectory($probeDirectory)|Out-Null
    Add-Type -TypeDefinition 'public static class RooIndustriesGovernorProbe { public static void Main(string[] args) { System.Threading.Thread.Sleep(System.TimeSpan.FromSeconds(args.Length > 0 ? int.Parse(args[0]) : 600)); } }' -OutputAssembly (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -OutputType ConsoleApplication
    Assert (@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count -eq 0) 'The desktop app is not running during governor validation'

    $first=Start-Probe
    if($null -eq (Wait-Until {$null -ne (Read-Controls $first)} 15)){throw 'The probe did not become readable.'}
    $original=Read-Controls $first
    $snapshot=Core 'process-status' @{processId=$first.Id}
    $topology=@($snapshot.topology|Sort-Object group,index)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$topologyHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($topology|ForEach-Object {''+$_.group+':'+$_.index+':'+$_.core+':'+$_.cache+':'+$_.numa+':'+$_.efficiency}) -join ';'))))).Replace('-','')}
    finally {$sha.Dispose()}
    $cpu=@($topology|Where-Object {$_.available -and $_.group -eq 0})[1]
    $gpu=if($original.gpuPriority -eq 1){2}else{1}
        $cpuClass=if($original.cpuPriority -eq 'AboveNormal'){'High'}else{'AboveNormal'}
        $io=if($original.ioPriority -eq 2){1}else{2}
        $memory=if($original.memoryPriority -eq 3){4}else{3}
    $wanted=[ordered]@{cpuPriority=$cpuClass;affinity='0x3';cpuSets=[string]$cpu.id;ioPriority=$io;gpuPriority=$gpu;memoryPriority=$memory;executionQoS='eco';priorityBoostDisabled=$true}
    Note 'originalControls' $original
    Note 'requestedControls' $wanted
    Assert (-not (Same $original $wanted) -and  $original.executionQoS -ne 'eco' -and -not $original.priorityBoostDisabled -and $original.affinity -ne '0x3' -and $original.cpuSets -eq '') 'Every requested control differs from the fresh process default'
    $rule=@{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=(Get-RooIndustriesOperationOwner);name='Disposable governor validation';enabled=$true
        matchMode='path';executablePath=$first.MainModule.FileName;executableHash=$null;affinityTopologyHash=$topologyHash
        controls=@{cpuPriority=$cpuClass;affinity=@{group=0;mask='0x3'};ioPriority=$io;gpuPriority=$gpu;memoryPriority=$memory;executionQoS=@{controlMask=1;stateMask=1};priorityBoost=$false}
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
    $expected=New-RooIndustriesElevatedTaskAction $DotNetPath @((Join-Path $hostDirectory 'Optimizer.Host.dll'),'policy-run',(Join-Path $policyRoot 'worker-request.json')) $hostDirectory
    Assert ($task.Actions[0].Execute -eq $expected.Execute -and $task.Actions[0].Arguments -ceq $expected.Arguments -and $task.Actions[0].WorkingDirectory -eq $expected.WorkingDirectory) 'The governor runs without a console window and receives its host, command and protected request path through the clean launcher'
    $launcher=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Start-RooIndustriesHelper.cmd')
    Assert (((@([regex]::Matches($launcher,'(?m)^set ([A-Za-z0-9_()]+)=\r?$')|ForEach-Object {$_.Groups[1].Value})|Sort-Object) -join ',') -eq ((@($script:RooIndustriesCodeLoadingVariables)|Sort-Object) -join ',')) 'The clean launcher clears exactly the .NET code-loading settings the helpers refuse or ignore'
    Assert (((@([regex]::Matches($launcher,'(?m)^set ([A-Za-z0-9_()]+)=0\r?$')|ForEach-Object {$_.Groups[1].Value})|Sort-Object) -join ',') -eq ((@($script:RooIndustriesPinnedVariables)|Sort-Object) -join ',')) 'The clean launcher switches .NET diagnostics off under both name prefixes'
    $worker=Get-CimInstance Win32_Process -Filter ('ProcessId='+$synced.worker.state.host.processId)
    $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$worker.ParentProcessId)
    Note 'workerProcess' ([ordered]@{name=$worker.Name;commandLine=$worker.CommandLine;parent=$parent.Name;parentCommandLine=$parent.CommandLine;session=$worker.SessionId})
    $console=Get-CimInstance Win32_Process -Filter ('ProcessId='+$parent.ParentProcessId)
    Assert ($parent.Name -eq 'cmd.exe' -and $parent.CommandLine -like '*/d /v:off /c call *Start-RooIndustriesHelper.cmd*' -and $console.Name -eq 'conhost.exe' -and $console.CommandLine -like '*--headless*') 'The running governor is started by the clean launcher inside a headless console'
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
    $firstRecords=@((Core 'policy-status').state.instances|Where-Object {$_.process.processId -eq $first.Id -and $_.status -eq 'active'})
    Assert ($firstRecords.Count -eq 8 -and @($firstRecords|ForEach-Object {$_.field}|Sort-Object -Unique).Count -eq 8) 'The running process has one active journal per field before the crash'
    $firstInstance=@($firstRecords|Where-Object {$_.field -eq 'memoryPriority'})
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
    $afterMemory=@($after|Where-Object {$_.field -eq 'memoryPriority'})
    Assert ($null -ne $reconciled -and $after.Count -eq 8 -and $afterMemory.Count -eq 1 -and $afterMemory[0].journalPath -eq $firstInstance[0].journalPath -and $afterMemory[0].status -eq 'active' -and (Read-RooIndustriesOperationJson $afterMemory[0].journalPath).data.status -eq 'applied') 'The restarted governor reconciles the crashed journal, finishes the interrupted write and keeps the same recovery record'
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
    Core 'process-preview' @{processId=$first.Id;controls=@{memoryPriority=5};outputPath=$previewPath}|Out-Null
    $directError=$null
    try {Core 'process-apply' @{previewPath=$previewPath;reviewHash=(Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash;journalPath=(Join-Path $root 'direct-journal.json')}|Out-Null} catch {$directError=$_.Exception.Message}
    Assert ($directError -like 'Managed by the governor*' -and [RooIndustriesGovernorOracle]::Memory($first.Handle) -eq $memory) 'Apply once refuses a process field that the governor owns'

    # bounded history: many short-lived processes leave at most 50 finished records and no orphan folders
    for($index=0;$index -lt 55;$index++){
        $short=Start-Probe
        if($null -eq (Wait-Until {[RooIndustriesGovernorOracle]::Memory($short.Handle) -eq $memory} 5)){throw 'A short-lived process did not get its rule.'}
        $short.Kill();$short.WaitForExit()
    }
    $bounded=Wait-Until {$instances=@((Core 'policy-status').state.instances);@($instances|Where-Object {$_.status -notin @('restored','expired')}).Count -le 24 -and @($instances|Where-Object {$_.status -in @('restored','expired')}).Count -eq 50} 20 500
    $instances=@((Core 'policy-status').state.instances)
    $folders=@(Get-ChildItem -LiteralPath (Join-Path $policyRoot 'operations') -Directory)
    Note 'historyAfter55ShortProcesses' ([ordered]@{instances=$instances.Count;finished=@($instances|Where-Object {$_.status -in @('restored','expired')}).Count;operationFolders=$folders.Count})
    Assert ($null -ne $bounded -and $folders.Count -eq $instances.Count) 'After 55 short-lived processes the governor keeps exactly 50 finished records and deletes the pruned operation folders'

    # (e) deleting the last rule stops the governor, removes the task and restores values
    Core 'rule-delete' @{ruleId=$rule.ruleId}|Out-Null
    $removed=Worker 'Sync'
    Assert (-not $removed.registered -and $removed.worker.hostRunning -eq $false -and -not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) 'Deleting the last rule stops the governor and removes its task and triggers'
    Assert ((Same (Read-Controls $first) $original) -and (Same (Read-Controls $third) $original)) 'Deleting the last rule restores every running process'
    # anti-cheat style denial: a process that denies set and query access to its own user
    $deniedExe=Join-Path $probeDirectory 'RooIndustriesGovernorDenied.exe'
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Security.Principal; using System.Threading;
public static class RooIndustriesGovernorDenied {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Trustee { public IntPtr Multiple; public int Operation; public int Form; public int Type; public IntPtr Name; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Access { public uint Permissions; public int Mode; public uint Inheritance; public Trustee Trustee; }
    [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(IntPtr handle, int type, int info, IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern uint SetEntriesInAcl(int count, ref Access entries, IntPtr old, out IntPtr acl);
    [DllImport("advapi32.dll")] static extern uint SetSecurityInfo(IntPtr handle, int type, int info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    public static void Main(string[] args) {
        Thread.Sleep(TimeSpan.FromSeconds(int.Parse(args[0])));
        var sid = WindowsIdentity.GetCurrent().User; var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        var pointer = Marshal.AllocHGlobal(bytes.Length); Marshal.Copy(bytes, 0, pointer, bytes.Length);
        IntPtr dacl, descriptor, updated;
        if (GetSecurityInfo(GetCurrentProcess(), 6, 4, IntPtr.Zero, IntPtr.Zero, out dacl, IntPtr.Zero, out descriptor) != 0) Environment.Exit(3);
        var entry = new Access { Permissions = 0x200 | 0x400 | 0x1000, Mode = 3, Inheritance = 0, Trustee = new Trustee { Form = 0, Type = 1, Name = pointer } };
        if (SetEntriesInAcl(1, ref entry, dacl, out updated) != 0 || SetSecurityInfo(GetCurrentProcess(), 6, 4, IntPtr.Zero, IntPtr.Zero, updated, IntPtr.Zero) != 0) Environment.Exit(4);
        Thread.Sleep(TimeSpan.FromSeconds(int.Parse(args[1])));
    }
}
'@ -OutputAssembly $deniedExe -OutputType ConsoleApplication
    [Diagnostics.Process]::EnterDebugMode()
    $deniedRule=$rule.Clone();$deniedRule.ruleId=[Guid]::NewGuid().ToString('N');$deniedRule.name='Denied fixture';$deniedRule.executablePath=$deniedExe
    $deniedStart=[Diagnostics.ProcessStartInfo]::new($deniedExe,'0 180');$deniedStart.UseShellExecute=$false;$deniedStart.CreateNoWindow=$true
    $deniedNow=[Diagnostics.Process]::Start($deniedStart);$probes.Add($deniedNow)
    Start-Sleep -Seconds 2
    $deniedBaseline=$null;$null=Wait-Until {$script:deniedBaseline=Read-Controls $deniedNow;$true} 5
    Core 'rule-save' @{rule=$deniedRule}|Out-Null
    $deniedSync=Worker 'Sync'
    Assert ($deniedSync.worker.hostRunning -eq $true) 'The governor runs for the denial fixture rule' 
    $governor=Get-Process -Id (Get-WorkerIdentity).processId
    $governor.Refresh();$cpuBefore=$governor.TotalProcessorTime;$clock=[Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 30
    $governor.Refresh();$deniedCpu=[Math]::Round(100*($governor.TotalProcessorTime-$cpuBefore).TotalSeconds/$clock.Elapsed.TotalSeconds,3)
    $deniedState=(Core 'policy-status').state
    $deniedIssues=@($deniedState.issues|Where-Object {$_.processId -eq $deniedNow.Id})
    $deniedInstances=@($deniedState.instances|Where-Object {$_.process.processId -eq $deniedNow.Id})
    Note 'deniedAtStart' ([ordered]@{cpuPercentOfOneCoreWhileDenied=$deniedCpu;issues=@($deniedIssues|ForEach-Object {$_.message});instances=$deniedInstances.Count;controls=(Read-Controls $deniedNow)})
    Assert ($deniedInstances.Count -eq 0 -and $deniedIssues.Count -eq 1 -and $deniedIssues[0].message -like '*Win32 5*' -and $deniedIssues[0].kind -eq 'denied' -and (Same (Read-Controls $deniedNow) $deniedBaseline)) 'A process that denies access at start is shown unavailable and never applied'
    Assert ($deniedCpu -lt 5) ('Denied access does not cause a retry storm ('+$deniedCpu+'% of one core over 30 s)')
    $deniedLater=[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName=$deniedExe;Arguments='5 120';UseShellExecute=$false;CreateNoWindow=$true});$probes.Add($deniedLater)
    Assert ($null -ne (Wait-Until {Same (Read-Controls $deniedLater) $wanted} 4)) 'A process that denies access later first gets its rules'
    $stepped=Wait-Until {$records=@((Core 'policy-status').state.instances|Where-Object {$_.process.processId -eq $deniedLater.Id -and $_.status -notin @('restored','expired')});$records.Count -eq 8 -and @($records|Where-Object {$_.errorKind -eq 'denied' -and $_.error -like '*Win32 5*'}).Count -eq 8} 15 500
    Assert ($null -ne $stepped) 'After the process denies access its record steps back with the access error, shown as unavailable'
    $deniedPaused=Worker 'Pause'
    $reported=@($deniedPaused.worker.state.instances|Where-Object {$_.process.processId -eq $deniedLater.Id})
    Note 'deniedAfterApplyPause' ([ordered]@{status=$reported[0].status;error=$reported[0].error;stateStatus=$deniedPaused.worker.state.status;controls=(Read-Controls $deniedLater)})
    Assert ($reported.Count -eq 8 -and @($reported|Where-Object {$_.status -eq 'conflict' -and $_.errorKind -eq 'denied' -and $_.error -like '*Win32 5*'}).Count -eq 8 -and $deniedPaused.worker.state.status -eq 'stoppedWithConflicts' -and (Same (Read-Controls $deniedLater) $wanted)) 'Pause cannot restore a process that denies access and reports it instead of claiming success'
    foreach($fixture in @($deniedNow,$deniedLater)){$fixture.Kill();$fixture.WaitForExit()}
    Worker 'Resume'|Out-Null
    Core 'rule-delete' @{ruleId=$deniedRule.ruleId}|Out-Null
    $afterDenied=Worker 'Sync'
    Note 'afterDenied' ([ordered]@{registered=$afterDenied.registered;running=$afterDenied.worker.hostRunning;status=$afterDenied.worker.state.status;open=@($afterDenied.worker.state.instances|Where-Object {$_.status -notin @('restored','expired')}|ForEach-Object {''+$_.process.processId+' '+$_.process.executablePath+' '+$_.status+' '+$_.error})})
    Assert (-not $afterDenied.registered -and @($afterDenied.worker.state.instances|Where-Object {$_.status -notin @('restored','expired')}).Count -eq 0) 'Records of the denied processes end once they exit'

    # crash between restoring two fields: restart finishes every field and leaves a consistent journal
    $crashRule=$rule.Clone();$crashRule.ruleId=[Guid]::NewGuid().ToString('N');$crashRule.name='Crash during restore'
    Core 'rule-save' @{rule=$crashRule}|Out-Null
    Worker 'Sync'|Out-Null
    Assert ($null -ne (Wait-Until {Same (Read-Controls $first) $wanted} 10)) 'The crash-restore rule is applied'
    Worker 'Pause'|Out-Null
    Core 'policy-pause' @{paused=$false}|Out-Null
    $env:ROO_INDUSTRIES_TEST_RESTORE_PAUSE_MS='4000'
    $manual=Start-Process -FilePath $DotNetPath -ArgumentList ('"'+(Join-Path $hostDirectory 'Optimizer.Host.dll')+'" policy-run "'+(Join-Path $policyRoot 'worker-request.json')+'"') -WindowStyle Hidden -PassThru
    Remove-Item Env:\ROO_INDUSTRIES_TEST_RESTORE_PAUSE_MS
    Assert ($null -ne (Wait-Until {Same (Read-Controls $first) $wanted} 15)) 'A worker with the restore pause hook applies the rule'
    $crashInstance=@((Core 'policy-status').state.instances|Where-Object {$_.process.processId -eq $first.Id -and $_.status -eq 'active'})[0]
    $crashRule.enabled=$false
    Core 'rule-save' @{rule=$crashRule}|Out-Null
    $midway=Wait-Until {@((Read-RooIndustriesOperationJson $crashInstance.journalPath).data.changes|Where-Object {$_.status -eq 'restored'}).Count -eq 1} 120 100
    $manual.Kill();$manual.WaitForExit()
    $crashJournal=(Read-RooIndustriesOperationJson $crashInstance.journalPath).data
    $controlsAtCrash=Read-Controls $first
    Note 'crashDuringRestore' ([ordered]@{journalStatus=$crashJournal.status;changes=@($crashJournal.changes|ForEach-Object {$_.name+':'+$_.status});controls=$controlsAtCrash})
    Assert ($null -ne $midway -and -not (Same $controlsAtCrash $original) -and -not (Same $controlsAtCrash $wanted)) 'The worker was killed after restoring one field and before the others'
    Worker 'Sync'|Out-Null
    $finished=(Read-RooIndustriesOperationJson $crashInstance.journalPath).data
    Note 'afterCrashRestart' ([ordered]@{journalStatus=$finished.status;changes=@($finished.changes|ForEach-Object {$_.name+':'+$_.status});controls=(Read-Controls $first)})
    Assert ($finished.status -eq 'restored' -and @($finished.changes|Where-Object {$_.status -notin @('restored','unchanged')}).Count -eq 0 -and (Same (Read-Controls $first) $original)) 'After restart every field is back to its original and the journal is consistent'
    Core 'rule-delete' @{ruleId=$crashRule.ruleId}|Out-Null
    Worker 'Sync'|Out-Null

    # a running game session owns its fields, so an overlapping rule is refused until the session stops
    $gameDirectory=Join-Path $root 'game'
    [IO.Directory]::CreateDirectory($gameDirectory)|Out-Null
    $gameExe=Join-Path $gameDirectory 'RooIndustriesGovernorGame.exe'
    $launcherExe=Join-Path $gameDirectory 'RooIndustriesGovernorLauncher.exe'
    Copy-Item -LiteralPath (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -Destination $gameExe
    Copy-Item -LiteralPath (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -Destination $launcherExe
    $launcher=[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{FileName=$launcherExe;Arguments='600';UseShellExecute=$false;CreateNoWindow=$true});$probes.Add($launcher)
    $controlsFile=Join-Path $gameDirectory 'controls.json'
    [IO.File]::WriteAllText($controlsFile,'{"gpuPriority":3}',[Text.UTF8Encoding]::new($false))
    $sessionScript=Join-Path $PSScriptRoot 'Invoke-ProtectedGameSession.ps1'
    $gameRule=$rule.Clone();$gameRule.ruleId=[Guid]::NewGuid().ToString('N');$gameRule.name='Game rule';$gameRule.executablePath=$gameExe;$gameRule.cpuSelection=$null
    $gameRule.controls=@{gpuPriority=1};$gameRule.affinityTopologyHash=$null
    Core 'operations-secure' @{operationsRoot=(Join-Path $policyParent 'operations')}|Out-Null
    function New-GameSessionPreview{
        $directory=Join-Path $policyParent ('operations\game-session-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        $file=Join-Path $directory 'preview.json'
        $result=(@(& $sessionScript -Action Preview -LauncherProcessId $launcher.Id -GamePath $gameExe -ControlsPath $controlsFile -PreviewPath $file -AcceptLauncherScope -HostDirectory $hostDirectory -DotNetPath $DotNetPath) -join "`n")|ConvertFrom-Json
        return [pscustomobject]@{file=$file;hash=$result.data.reviewHash;root=(Join-Path $directory 'session')}
    }
    $early=New-GameSessionPreview
    Core 'rule-save' @{rule=$gameRule}|Out-Null
    $earlyStart=$null;try {& $sessionScript -Action Start -PreviewPath $early.file -ReviewHash $early.hash -SessionRoot $early.root -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply|Out-Null} catch {$earlyStart=$_.Exception.Message}
    & $sessionScript -Action Stop -SessionRoot $early.root -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply|Out-Null
    Note 'sessionAfterRule' ([ordered]@{startError=$earlyStart;worker=$(if(Test-Path -LiteralPath (Join-Path $early.root 'worker-error.json')){[IO.File]::ReadAllText((Join-Path $early.root 'worker-error.json'))}else{$null})})
    Assert ($null -ne $earlyStart -and -not (Test-Path -LiteralPath (Join-Path $early.root 'session.json'))) 'A game session reviewed before a rule was saved for the same field does not start'
    Worker 'Pause'|Out-Null
    $pausedPreview=$null;try {New-GameSessionPreview|Out-Null} catch {$pausedPreview=$_.Exception.Message}
    Note 'sessionWhilePaused' $pausedPreview
    Assert ($pausedPreview -like '*Managed by the governor: gpuPriority*') 'A paused rule still keeps its fields from a new game session'
    Worker 'Resume'|Out-Null
    Core 'rule-delete' @{ruleId=$gameRule.ruleId}|Out-Null
    Worker 'Sync'|Out-Null
    $session=New-GameSessionPreview
    $sessionRoot=$session.root
    & $sessionScript -Action Start -PreviewPath $session.file -ReviewHash $session.hash -SessionRoot $sessionRoot -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply|Out-Null
    $sessionActive=$true
    $sessionRefusal=$null;try {Core 'rule-save' @{rule=$gameRule}|Out-Null} catch {$sessionRefusal=$_.Exception.Message}
    Note 'gameSessionRefusal' $sessionRefusal
    Assert ($sessionRefusal -like 'A game session for RooIndustriesGovernorGame.exe already controls gpuPriority*') 'Saving a rule that overlaps a running game session is refused with a clear message'
    $gameRule.controls=@{memoryPriority=3}
    Core 'rule-save' @{rule=$gameRule}|Out-Null
    Assert (@(Core 'rules-list').Count -eq 1) 'A rule for other fields of the same game can still be saved'
    & $sessionScript -Action Stop -SessionRoot $sessionRoot -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply|Out-Null
    $sessionActive=$false
    $gameRule.controls=@{gpuPriority=1}
    Core 'rule-save' @{rule=$gameRule}|Out-Null
    Assert (@(Core 'rules-list'|Where-Object {$_.controls.gpuPriority -eq 1}).Count -eq 1) 'After the game session stops the same rule can be saved'
    Core 'rule-delete' @{ruleId=$gameRule.ruleId}|Out-Null
    Worker 'Sync'|Out-Null

    # governor requests travel on standard input; a request file is refused and a racing non-elevated process finds nothing to rewrite
    $requestFile=Join-Path $root 'file-request.json'
    Write-RooIndustriesOperationJson @{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$policyRoot;confirm=$true;paused=$true} $requestFile
    $fileRefusal=(@(& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') 'policy-pause' $requestFile) -join "`n")|ConvertFrom-Json
    Assert ($fileRefusal.status -ne 'completed' -and $fileRefusal.error.message -eq 'Governor requests must be passed on standard input.' -and -not (Test-Path -LiteralPath (Join-Path $policyRoot 'governor.json.tmp'))) 'A governor request passed as a file is refused'
    Remove-Item -LiteralPath $requestFile -Force
    $watchOutput=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-watch-'+[Guid]::NewGuid().ToString('N')+'.json')
    Start-Limited (@'
$seen=New-Object System.Collections.Generic.List[string];$rewritten=New-Object System.Collections.Generic.List[string];$errors=New-Object System.Collections.Generic.List[string]
$known=@{};$passes=0;$since=[DateTime]::UtcNow.AddSeconds(-1)
$clock=[Diagnostics.Stopwatch]::StartNew()
while($clock.Elapsed.TotalSeconds -lt 90){
    try{
        $temp=[IO.Path]::GetTempPath()
        $candidates=@([IO.Directory]::GetFiles($temp,'*.json'))
        foreach($folder in [IO.Directory]::GetDirectories($temp,'roo-industries-*')){try{$candidates+=@([IO.Directory]::GetFiles($folder,'*.json'))}catch{}}
        try{$candidates+=@([IO.Directory]::GetFiles('PARENT','*.json',[IO.SearchOption]::AllDirectories))}catch{$errors.Add('parent: '+$_.Exception.Message)}
        foreach($path in $candidates){
            try{$written=[IO.File]::GetLastWriteTimeUtc($path)}catch{continue}
            if($written -lt $since -or $known[$path] -eq $written.Ticks){continue}
            $known[$path]=$written.Ticks
            try{$text=[IO.File]::ReadAllText($path)}catch{continue}
            if($text -notmatch 'policyRoot'){continue}
            $seen.Add($path)
            try{[IO.File]::WriteAllText($path,$text.Replace('"paused":false','"paused":true').Replace('"paused": false','"paused": true'));$rewritten.Add($path);$known[$path]=[IO.File]::GetLastWriteTimeUtc($path).Ticks}catch{}
        }
        $passes++
    }catch{$errors.Add($_.Exception.Message)}
    Start-Sleep -Milliseconds 100
}
@{elevated=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);seen=@($seen|Select-Object -Unique);rewritten=@($rewritten);passes=$passes;errors=@($errors|Select-Object -First 5)}|ConvertTo-Json|Set-Content -LiteralPath 'OUT' -Encoding UTF8
'@).Replace('PARENT',$policyParent).Replace('OUT',$watchOutput)
    Start-Sleep -Seconds 3
    $raceRule=$rule.Clone();$raceRule.ruleId=[Guid]::NewGuid().ToString('N');$raceRule.name='Race rule'
    Core 'rule-save' @{rule=$raceRule}|Out-Null
    Worker 'Sync'|Out-Null
    Worker 'Pause'|Out-Null
    $raceResumed=Worker 'Resume'
    Core 'rule-delete' @{ruleId=$raceRule.ruleId}|Out-Null
    Worker 'Sync'|Out-Null
    $decoy=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-decoy-'+[Guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($decoy,'{"policyRoot":"decoy","paused":false}',[Text.UTF8Encoding]::new($false))
    if($null -eq (Wait-Until {Test-Path -LiteralPath $watchOutput} 150 500)){throw 'The request watcher did not report.'}
    $decoyText=[IO.File]::ReadAllText($decoy);Remove-Item -LiteralPath $decoy -Force
    Start-Sleep -Milliseconds 300
    $watch=Get-Content -LiteralPath $watchOutput -Raw -Encoding UTF8|ConvertFrom-Json
    Remove-Item -LiteralPath $watchOutput -Force
    Note 'requestRace' ([ordered]@{elevated=$watch.elevated;passes=$watch.passes;errors=@($watch.errors);seen=@($watch.seen);rewritten=@($watch.rewritten)})
    Assert ($decoyText -match '"paused":true' -and @($watch.rewritten|Where-Object {$_ -ne $decoy}).Count -eq 0 -and @($watch.rewritten) -contains $decoy) 'The racing watcher does catch and rewrite a request file when one exists (positive control)'
    Assert ($watch.elevated -eq $false -and $raceResumed.paused -eq $false -and $raceResumed.worker.hostRunning -eq $true) 'A non-elevated process racing governor actions finds no governor request it can rewrite'

    # migration of a folder written by the earlier version: a file written without elevation is refused, a clean folder moves byte for byte, an interrupted swap is adopted
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
    $legacyRefused=$null;try {Worker 'Sync' $legacyRoot|Out-Null} catch {$legacyRefused=$_.Exception.Message}
    Note 'legacyRefusal' $legacyRefused
    Assert ($legacyRefused -like '*did not write with administrator rights*' -and -not (Get-Acl -LiteralPath $legacyRoot).AreAccessRulesProtected) 'An earlier folder containing a file written without elevation is refused and left untouched'
    Remove-Item -LiteralPath (Join-Path $legacyRoot 'rules\note.txt') -Force
    $migrated=Worker 'Sync' $legacyRoot
    $legacyAcl=Get-Acl -LiteralPath $legacyRoot
    Note 'migratedAcl' ([ordered]@{owner=$legacyAcl.Owner;protected=$legacyAcl.AreAccessRulesProtected;access=@($legacyAcl.Access|ForEach-Object {''+$_.IdentityReference+':'+$_.FileSystemRights+':'+$_.AccessControlType})})
    Note 'migration' ([ordered]@{secured=$migrated.secured;running=$migrated.worker.hostRunning;error=$migrated.worker.error;sameBytes=((Get-FileHash -LiteralPath $legacyFile).Hash -eq $legacyHash);leftovers=@(Get-ChildItem -LiteralPath (Split-Path $legacyRoot -Parent) -Directory|ForEach-Object {$_.Name})})
    Assert ($migrated.secured -and $migrated.worker.hostRunning -eq $true -and (Get-FileHash -LiteralPath $legacyFile).Hash -eq $legacyHash -and $legacyAcl.Owner -eq 'BUILTIN\Administrators' -and $legacyAcl.AreAccessRulesProtected -and @(Get-ChildItem -LiteralPath (Split-Path $legacyRoot -Parent) -Directory|Where-Object {$_.Name -like 'process-rules.*'}).Count -eq 0) 'An earlier folder written by the elevated app is migrated byte for byte into a protected folder and the governor starts'
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
    if($moved -and (Test-Path -LiteralPath $moved)){if(Test-Path -LiteralPath $policyRoot){Remove-Item -LiteralPath $policyRoot -Recurse -Force};[IO.Directory]::Move($moved,$policyRoot)}
    if(Test-Path -LiteralPath (Join-Path $hostDirectory 'Optimizer.Host.dll')){
        try {Worker 'Remove'|Out-Null} catch {Write-Output ('Cleanup: '+$_.Exception.Message)}
        if(Test-Path -LiteralPath $legacyRoot){try {Worker 'Remove' $legacyRoot|Out-Null} catch {Write-Output ('Cleanup: '+$_.Exception.Message)}}
    }
    if($taskName -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    if($sessionActive){try {& (Join-Path $PSScriptRoot 'Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot $sessionRoot -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply|Out-Null} catch {Write-Output ('Cleanup: '+$_.Exception.Message)}}
    foreach($probe in $probes){try {if(-not $probe.HasExited){$probe.Kill()};$probe.WaitForExit();$probe.Dispose()} catch {}}
    Remove-Item -LiteralPath $limitedOutput -Force -ErrorAction SilentlyContinue
    $markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    if($markers){foreach($name in @($markers.GetValueNames()|Where-Object {$_ -like ('*\'+(Split-Path $root -Leaf).ToUpperInvariant()+'\*')})){Remove-ItemProperty -LiteralPath $markers.PSPath -Name $name}}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    $evidence.finishedAtUtc=[DateTime]::UtcNow.ToString('o')
    if($EvidencePath){[IO.File]::WriteAllText($EvidencePath,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
}
Assert (-not(Test-Path -LiteralPath $root) -and ($null -eq $taskName -or -not(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))) 'Governor validation removes its scheduled task, processes and temporary state'
