param([Parameter(Mandatory=$true)][string]$Phase,[string]$Installer='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$app='C:\Program Files\Roo Industries\Optimization Suite'
$hostExe=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe'
$workerScript=Join-Path $app 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'
$work=Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-governor-installed'
$statePath=Join-Path $work 'state.json'
$local=[Environment]::GetFolderPath('LocalApplicationData')
$markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
$currentRoot=Join-Path $local 'RooIndustriesOptimizationSuite';$legacyRoot=Join-Path $local ('RooIndustriesOptimizationSuite' -replace 'Industries','')
$dataRoot=if((Test-Path -LiteralPath $legacyRoot -PathType Container) -and -not ($markers -and $null -ne $markers.GetValue($currentRoot.ToUpperInvariant()) -and $null -eq $markers.GetValue($legacyRoot.ToUpperInvariant()))){$legacyRoot}else{$currentRoot}
$policyRoot=Join-Path $dataRoot 'process-rules'
[IO.Directory]::CreateDirectory($work)|Out-Null
$out=[ordered]@{phase=$Phase;atUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;policyRoot=$policyRoot;checks=@()}
function Check([bool]$Condition,[string]$Message){$script:out.checks+=[ordered]@{passed=$Condition;check=$Message};if($Condition){"PASS $Message"}else{"FAIL $Message"}}
$OutputEncoding=[Text.UTF8Encoding]::new($false)
function Host-Call([string]$Action,[hashtable]$Extra=@{}){
    $request=@{schemaVersion=1;repoRoot=$app;policyRoot=$policyRoot;confirm=$true}
    foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
    if((Test-Path -LiteralPath $workerScript) -and ([IO.File]::ReadAllText($workerScript) -match "'-'")){
        $result=(@(($request|ConvertTo-Json -Depth 12 -Compress)|& $hostExe $Action '-') -join "`n")|ConvertFrom-Json
        if($result.status -ne 'completed'){throw ($Action+': '+$result.error.message)}
        return $result.data
    }
    $path=Join-Path $work ('request-'+[Guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($path,($request|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    try {$result=(@(& $hostExe $Action $path) -join "`n")|ConvertFrom-Json} finally {Remove-Item -LiteralPath $path -Force}
    if($result.status -ne 'completed'){throw ($Action+': '+$result.error.message)}
    return $result.data
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesInstalledOracle {
    [StructLayout(LayoutKind.Sequential)] struct Throttling { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr process, int kind, out uint value, uint size);
    [DllImport("kernel32.dll", SetLastError=true, EntryPoint="GetProcessInformation")] static extern bool GetThrottling(IntPtr process, int kind, ref Throttling value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessPriorityBoost(IntPtr process, out bool disabled);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process, uint[] ids, uint count, out uint required);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, out int value, int size, IntPtr length);
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    public static uint Memory(IntPtr p) { uint v; if(!GetProcessInformation(p,0,out v,4)) throw new System.ComponentModel.Win32Exception(); return v; }
    public static string Qos(IntPtr p) { var t=new Throttling{Version=1}; if(!GetThrottling(p,4,ref t,12)) throw new System.ComponentModel.Win32Exception(); return (t.ControlMask&1)==0?"systemManaged":(t.StateMask&1)!=0?"eco":"high"; }
    public static bool BoostDisabled(IntPtr p) { bool d; if(!GetProcessPriorityBoost(p,out d)) throw new System.ComponentModel.Win32Exception(); return d; }
    public static string CpuSets(IntPtr p) { uint n; GetProcessDefaultCpuSets(p,null,0,out n); var ids=new uint[n]; if(n>0 && !GetProcessDefaultCpuSets(p,ids,n,out n)) throw new System.ComponentModel.Win32Exception(); return string.Join(",",ids); }
    public static int Io(IntPtr p) { int v; int s=NtQueryInformationProcess(p,33,out v,4,IntPtr.Zero); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
    public static int Gpu(IntPtr p) { int v; int s=D3DKMTGetProcessSchedulingPriorityClass(p,out v); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
}
'@
function Read-Controls([Diagnostics.Process]$Process){
    $Process.Refresh()
    return [ordered]@{cpuPriority=[string]$Process.PriorityClass;affinity=('0x{0:X}' -f [int64]$Process.ProcessorAffinity);cpuSets=[RooIndustriesInstalledOracle]::CpuSets($Process.Handle)
        ioPriority=[RooIndustriesInstalledOracle]::Io($Process.Handle);gpuPriority=[RooIndustriesInstalledOracle]::Gpu($Process.Handle);memoryPriority=[RooIndustriesInstalledOracle]::Memory($Process.Handle)
        executionQoS=[RooIndustriesInstalledOracle]::Qos($Process.Handle);priorityBoostDisabled=[RooIndustriesInstalledOracle]::BoostDisabled($Process.Handle)}
}
function Same($Left,$Right){return (($Left|ConvertTo-Json -Compress) -eq ($Right|ConvertTo-Json -Compress))}
function Wait-Until([scriptblock]$Condition,[double]$Seconds){$clock=[Diagnostics.Stopwatch]::StartNew();while($true){$met=$false;try{$met=[bool](& $Condition)}catch{};if($met){break};if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null};Start-Sleep -Milliseconds 50};return [Math]::Round($clock.Elapsed.TotalSeconds,3)}
$probeExe=Join-Path $work 'probe\RooIndustriesGovernorProbe.exe'
function Start-Probe {
    $info=[Diagnostics.ProcessStartInfo]::new($probeExe,'7200');$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    return [Diagnostics.Process]::Start($info)
}
function Get-Probe([int]$Id){try{$p=Get-Process -Id $Id -ErrorAction Stop;if($p.Path -eq $probeExe){return $p}}catch{};return $null}
function Tasks{@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like '*OptimizationSuite.ProcessRules.*'})}
function Workers{@(Get-CimInstance Win32_Process|Where-Object {$_.Name -in @('Optimizer.Host.exe','dotnet.exe') -and [string]$_.CommandLine -match 'policy-run'})}
function Describe-State {
    $result=[ordered]@{}
    $result.tasks=@(Tasks|ForEach-Object {[ordered]@{name=$_.TaskName;state=[string]$_.State;execute=$_.Actions[0].Execute;arguments=$_.Actions[0].Arguments;runLevel=[string]$_.Principal.RunLevel;triggers=@($_.Triggers|ForEach-Object {[ordered]@{kind=$_.CimClass.CimClassName;interval=$_.Repetition.Interval;duration=$_.Repetition.Duration}})}})
    Mark 'tasks'
    $result.workers=@(Workers|ForEach-Object {[ordered]@{pid=$_.ProcessId;name=$_.Name;path=$_.ExecutablePath;session=$_.SessionId;commandLine=$_.CommandLine}})
    Mark 'workers'
    $status=if(Test-Path -LiteralPath $hostExe){try{Host-Call 'policy-status'}catch{$_.Exception.Message}}else{'no host'}
    Mark 'status'
    $result.hostRunning=$status.hostRunning;$result.stateStatus=$status.state.status;$result.hostPid=$status.state.host.processId
    $result.instances=@($status.state.instances|ForEach-Object {[ordered]@{pid=$_.process.processId;status=$_.status;journal=$_.journalPath}})
    Mark 'instances'
    $result.ruleFiles=@(if(Test-Path -LiteralPath (Join-Path $policyRoot 'rules')){Get-ChildItem -LiteralPath (Join-Path $policyRoot 'rules') -Filter *.json|ForEach-Object {[ordered]@{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}}})
    Mark 'rules'
    $result.governorJson=if(Test-Path -LiteralPath (Join-Path $policyRoot 'governor.json')){[IO.File]::ReadAllText((Join-Path $policyRoot 'governor.json'))}else{$null}
    $acl=if(Test-Path -LiteralPath $policyRoot){Get-Acl -LiteralPath $policyRoot}else{$null}
    $result.rootOwner=if($acl){$acl.Owner}else{$null};$result.rootProtected=if($acl){$acl.AreAccessRulesProtected}else{$null}
    $result.rootAccess=if($acl){@($acl.Access|ForEach-Object {''+$_.IdentityReference+':'+$_.FileSystemRights+':'+$_.AccessControlType+':'+$_.IsInherited})}else{$null}
    Mark 'acl'
    $result.appRunning=@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count
    $dll=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.dll'
    $result.hostFile=if(Test-Path -LiteralPath $dll){[ordered]@{lastWriteUtc=(Get-Item -LiteralPath $dll).LastWriteTimeUtc.ToString("o");createdUtc=(Get-Item -LiteralPath $dll).CreationTimeUtc.ToString("o");sha256=(Get-FileHash -LiteralPath $dll).Hash}}else{$null}
    Mark 'hostFile'
    $result.bootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    Mark 'boot'
    return $result
}
function Mark([string]$Name){if($env:ROO_INDUSTRIES_GOVERNOR_TRACE){[IO.File]::AppendAllText($env:ROO_INDUSTRIES_GOVERNOR_TRACE,$Name+' '+[DateTime]::Now.ToString('HH:mm:ss.fff')+"`r`n")}}
$state=if(Test-Path -LiteralPath $statePath){Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json}else{[pscustomobject]@{}}
function Save-State{[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
function Set-StateValue([string]$Name,$Value){if($state.PSObject.Properties[$Name]){$state.$Name=$Value}else{$state|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}}

switch($Phase){
    'describe' {$out.state=Describe-State}
    'create-rule' {
        [IO.Directory]::CreateDirectory((Split-Path $probeExe -Parent))|Out-Null
        if(-not (Test-Path -LiteralPath $probeExe)){Add-Type -TypeDefinition 'public static class RooIndustriesGovernorProbe { public static void Main(string[] args) { System.Threading.Thread.Sleep(System.TimeSpan.FromSeconds(args.Length > 0 ? int.Parse(args[0]) : 600)); } }' -OutputAssembly $probeExe -OutputType ConsoleApplication}
        $probe=Start-Probe
        Wait-Until {$null -ne (Read-Controls $probe)} 15|Out-Null
        $original=Read-Controls $probe
        $snapshot=Host-Call 'process-status' @{processId=$probe.Id}
        $topology=@($snapshot.topology|Sort-Object group,index)
        $sha=[Security.Cryptography.SHA256]::Create()
        $topologyHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($topology|ForEach-Object {''+$_.group+':'+$_.index+':'+$_.core+':'+$_.cache+':'+$_.numa+':'+$_.efficiency}) -join ';'))))).Replace('-','')
        $cpu=@($topology|Where-Object {$_.available -and $_.group -eq 0})[1]
        $gpu=if($original.gpuPriority -eq 1){2}else{1}
        $cpuClass=if($original.cpuPriority -eq 'AboveNormal'){'High'}else{'AboveNormal'}
        $io=if($original.ioPriority -eq 2){1}else{2}
        $memory=if($original.memoryPriority -eq 3){4}else{3}
        $wanted=[ordered]@{cpuPriority=$cpuClass;affinity='0x3';cpuSets=[string]$cpu.id;ioPriority=$io;gpuPriority=$gpu;memoryPriority=$memory;executionQoS='eco';priorityBoostDisabled=$true}
        $rule=@{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value};name='Installed governor validation';enabled=$true
            matchMode='path';executablePath=$probeExe;executableHash=$null;affinityTopologyHash=$topologyHash
            controls=@{cpuPriority=$cpuClass;affinity=@{group=0;mask='0x3'};ioPriority=$io;gpuPriority=$gpu;memoryPriority=$memory;executionQoS=@{controlMask=1;stateMask=1};priorityBoost=$false}
            cpuSelection=@{kind='logical';topologyHash=$topologyHash;processors=@(@{group=0;index=[int]$cpu.index});oneThreadPerCore=$false}}
        Host-Call 'rule-save' @{rule=$rule}|Out-Null
        $legacy=([IO.File]::ReadAllText($workerScript) -notmatch "'Sync'")
        $text=if($legacy){@(& $workerScript -Action Start -PolicyRoot $policyRoot -ConfirmApply) -join "`n"}else{@(& $workerScript -Action Sync -PolicyRoot $policyRoot -ConfirmApply) -join "`n"}
        $out.startResult=$text|ConvertFrom-Json
        $applied=Wait-Until {Same (Read-Controls $probe) $wanted} 10
        Set-StateValue 'probePid' $probe.Id;Set-StateValue 'original' $original;Set-StateValue 'wanted' $wanted;Set-StateValue 'ruleId' $rule.ruleId;Set-StateValue 'legacyVersion' $legacy
        Save-State
        $out.legacyVersion=$legacy;$out.appliedSeconds=$applied
        Check ($null -ne $applied) ('The '+$(if($legacy){'earlier'}else{'new'})+' installed version applies all 8 controls to the probe')
        $out.state=Describe-State
    }
    'verify-running' {
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check ($s.appRunning -eq 0) 'The desktop app is not running'
        Check ($s.hostRunning -eq $true -and @($s.workers).Count -eq 1) 'Exactly one governor worker is running and its identity is live'
        Check (@($s.workers).Count -eq 1 -and $s.workers[0].path -ieq $hostExe -and $hostExe.StartsWith('C:\Program Files\',[StringComparison]::OrdinalIgnoreCase)) 'The governor worker runs from the installed Optimizer.Host.exe under C:\Program Files'
        $workerRow=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$s.hostPid) -ErrorAction SilentlyContinue
        $launcherRow=if($workerRow){Get-CimInstance Win32_Process -Filter ('ProcessId='+$workerRow.ParentProcessId) -ErrorAction SilentlyContinue}
        $consoleRow=if($launcherRow){Get-CimInstance Win32_Process -Filter ('ProcessId='+$launcherRow.ParentProcessId) -ErrorAction SilentlyContinue}
        Check ($launcherRow -and $consoleRow -and $launcherRow.Name -eq 'cmd.exe' -and $launcherRow.CommandLine -match 'Start-RooIndustriesHelper\.cmd' -and $consoleRow.Name -eq 'conhost.exe' -and $consoleRow.CommandLine -match '--headless') 'The governor worker was started through the clean launcher under a hidden console host'
        . (Join-Path $app 'backend\scripts\BrandCompatibility.Common.ps1')
        Check (@($s.tasks).Count -eq 1 -and $s.tasks[0].state -ne 'Disabled' -and $s.tasks[0].execute -like '*\conhost.exe' -and $s.tasks[0].arguments -ceq (New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',(Join-Path $policyRoot 'worker-request.json')) (Split-Path $hostExe -Parent)).Arguments -and @($s.tasks[0].triggers|Where-Object {$_.kind -eq 'MSFT_TaskLogonTrigger' -and $_.interval -eq 'PT1M'}).Count -eq 1 -and @($s.tasks[0].triggers|Where-Object {$_.kind -eq 'MSFT_TaskTimeTrigger' -and $_.interval -eq 'PT1M'}).Count -eq 1) 'One enabled governor task runs the installed host headless with sign-in and one-minute triggers'
        Check ($s.rootOwner -eq 'BUILTIN\Administrators' -and $s.rootProtected -and @($s.rootAccess|Where-Object {$_ -match 'FullControl' -and $_ -notmatch '^(NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators):'}).Count -eq 0) 'The rules folder is owned by Administrators with no inherited or user write access'
        Check (@($s.ruleFiles).Count -ge 1 -and @($s.ruleFiles|Where-Object {$_.name -eq ($state.ruleId+'.json')}).Count -eq 1) 'The saved rule is still present'
        if($probe){Check (Same (Read-Controls $probe) $state.wanted) 'The long-running probe still has all 8 requested controls'}
        $fresh=Start-Probe
        $seconds=Wait-Until {Same (Read-Controls $fresh) $state.wanted} 10
        $out.newProcessSeconds=$seconds
        Check ($null -ne $seconds) ('A newly started probe gets all 8 controls ('+$seconds+' s)')
        . (Join-Path $app 'backend\scripts\ProcessProfile.Common.ps1')
        $current=Get-RooIndustriesProcessControlState $fresh.Id
        $plan=Get-RooIndustriesApplicableProcessControlChanges @([pscustomobject]@{control='priorityClass';proposedValue='High';blocked=$false},[pscustomobject]@{control='ioPriority';proposedValue='VeryLow';blocked=$false}) $current
        $out.powerShellPlan=@($plan.skippedControls|ForEach-Object {[string]$_.control+": "+[string]$_.category+" "+[string]$_.reason})
        $thrown=$null;try {Invoke-RooIndustriesProcessControlChange $fresh ([pscustomobject]@{control='priorityClass';proposedValue='High'})} catch {$thrown=$_.Exception.Message}
        Check (@($plan.changes).Count -eq 0 -and @($plan.skippedControls|Where-Object {$_.category -eq 'managed' -and $_.reason -eq 'Managed by the governor'}).Count -eq 2 -and $thrown -eq 'Managed by the governor' -and (Same (Read-Controls $fresh) $state.wanted)) 'GameTune, Background limits and Background profile skip or refuse fields the governor owns and report Managed by the governor'
        $fresh.Kill();$fresh.WaitForExit()
    }
    'measure' {
        $s=Describe-State;$out.state=$s
        $worker=Get-Process -Id $s.hostPid -ErrorAction Stop
        $seconds=60
        $before=$worker.TotalProcessorTime;$started=Get-Date
        Start-Sleep -Seconds $seconds
        $worker.Refresh()
        $elapsed=((Get-Date)-$started).TotalSeconds
        $cpu=[Math]::Round((($worker.TotalProcessorTime-$before).TotalSeconds/$elapsed)*100,2)
        $out.measurement=[ordered]@{seconds=[Math]::Round($elapsed,1);cpuPercentOfOneCore=$cpu;workingSetMB=[Math]::Round($worker.WorkingSet64/1MB,1);privateMB=[Math]::Round($worker.PrivateMemorySize64/1MB,1);threads=$worker.Threads.Count;handles=$worker.HandleCount}
        Check ($cpu -lt 5 -and $worker.WorkingSet64 -lt 80MB) ('The idle governor stays light: '+$cpu+' percent of one core, '+[Math]::Round($worker.WorkingSet64/1MB,1)+' MB working set over '+[Math]::Round($elapsed)+' s')
    }
    'app-cycle' {
        $before=Describe-State
        $exe=Join-Path $app 'app\RooIndustries.OptimizationSuite.App.exe'
        $process=Start-Process $exe -PassThru
        Start-Sleep -Seconds 20
        $during=Describe-State
        $process.CloseMainWindow()|Out-Null
        if(-not $process.WaitForExit(20000)){$process.Kill()}
        Start-Sleep -Seconds 3
        $after=Describe-State
        $probe=Get-Probe $state.probePid
        $out.before=$before;$out.during=$during;$out.after=$after
        Check ($before.hostPid -and $before.hostPid -eq $during.hostPid -and $during.hostPid -eq $after.hostPid -and $after.hostRunning -eq $true) 'Opening and closing the app leaves the same governor running'
        if($probe){Check (Same (Read-Controls $probe) $state.wanted) 'The probe keeps its rules after the app closes'}
    }
    'legacy-before' {
        $before=Describe-State;$out.before=$before
        $scriptPath=Join-Path $work 'limited.ps1';$result=Join-Path $work 'limited.json';Remove-Item -LiteralPath $result -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($scriptPath,("`$r=[ordered]@{elevated=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}`ntry{[IO.File]::WriteAllText('"+(Join-Path $policyRoot 'rules\planted-by-user.txt')+"','x');`$r.createInRules='allowed'}catch{`$r.createInRules='denied: '+`$_.Exception.Message}`n`$r|ConvertTo-Json|Set-Content -LiteralPath '"+$result+"'"),[Text.UTF8Encoding]::new($true))
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([IO.File]::ReadAllText($scriptPath)))
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\runas.exe') -ArgumentList ('/trustlevel:0x20000 "'+(Join-Path $env:SystemRoot 'System32\conhost.exe')+' --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded+'"') -WindowStyle Hidden -Wait
        Wait-Until {Test-Path -LiteralPath $result} 60|Out-Null
        $out.limited=Get-Content -Raw -LiteralPath $result|ConvertFrom-Json
        Remove-Item -LiteralPath (Join-Path $policyRoot 'rules\planted-by-user.txt') -Force -ErrorAction SilentlyContinue
        Check ($out.limited.elevated -eq $false -and $out.limited.createInRules -eq 'allowed') 'BEFORE: a non-elevated process of the same user can write into the rules folder of the earlier version'
        $pid0=$before.hostPid
        Stop-Process -Id $pid0 -Force
        Start-Sleep -Seconds 95
        $after=Describe-State;$out.afterKill=$after
        Check ($after.hostRunning -ne $true) 'BEFORE: a killed worker of the earlier version is not restarted within 95 seconds'
        $text=@(& $workerScript -Action Stop -PolicyRoot $policyRoot -ConfirmApply) -join "`n"
        $text=@(& $workerScript -Action Start -PolicyRoot $policyRoot -ConfirmApply) -join "`n"
        $out.restarted=Describe-State
    }
    'new-probe' {
        $probe=Start-Probe
        $seconds=Wait-Until {Same (Read-Controls $probe) $state.wanted} 10
        Set-StateValue 'probePid' $probe.Id;Save-State
        $out.appliedSeconds=$seconds
        Check ($null -ne $seconds) ('A new long-running probe gets all 8 controls ('+$seconds+' s)')
    }
    'pause' {
        $text=@(& $workerScript -Action Pause -PolicyRoot $policyRoot -ConfirmApply) -join "`n"
        $out.pauseResult=$text|ConvertFrom-Json
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check ($out.pauseResult.status -eq 'completed' -and $out.pauseResult.data.paused -and @($s.workers).Count -eq 0 -and @($s.tasks).Count -eq 1 -and $s.tasks[0].state -eq 'Disabled') 'Pause stops the installed governor and disables its task'
        if($probe){Check (Same (Read-Controls $probe) $state.original) 'Pause gives the probe its original 8 controls back'}
    }
    'verify-paused' {
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check (@($s.tasks).Count -eq 1 -and $s.tasks[0].state -eq 'Disabled' -and @($s.workers).Count -eq 0 -and [string]$s.governorJson -match '"paused":\s*true') 'After setup the governor is still paused: task disabled, no worker, pause kept'
        if($probe){Check (Same (Read-Controls $probe) $state.original) 'After setup the paused rules are not applied to the probe'}
        Start-Sleep -Seconds 75
        $later=Describe-State;$out.later=$later
        Check (@($later.workers).Count -eq 0 -and $later.tasks[0].state -eq 'Disabled' -and (-not $probe -or (Same (Read-Controls $probe) $state.original))) 'Seventy-five seconds later nothing restarted the paused governor'
    }
    'kill-setup' {
        $probe=Get-Probe $state.probePid
        $before=Describe-State;$out.before=$before
        $setupLog=Join-Path $work 'setup-killed.log'
        Remove-Item -LiteralPath $setupLog -ErrorAction SilentlyContinue
        $setup=Start-Process -FilePath $Installer -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+$setupLog+'"') -PassThru
        $started=[DateTime]::Now.AddSeconds(-2)
        $suspended=Wait-Until {$log=Join-Path $app 'setup\governor-setup.log';(Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).LastWriteTime -ge $started -and ([IO.File]::ReadAllText($log) -match 'Suspend Suspended')} 120
        $killed=@(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -eq $setup.Id -or ($_.ExecutablePath -like '*\is-*.tmp\*' -and $_.Name -like 'RooIndustries-OptimizationSuite-*')}|Sort-Object {$_.ProcessId -eq $setup.Id})
        foreach($process in $killed){Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}
        [IO.File]::AppendAllText((Join-Path $work 'kill-progress.txt'),([DateTime]::UtcNow.ToString('o')+' killed '+(($killed|ForEach-Object {$_.Name+':'+$_.ProcessId}) -join ',')+"`r`n"))
        $killedAt=[DateTime]::UtcNow
        Start-Sleep -Seconds 2
        $afterKill=Describe-State;$out.afterKill=[ordered]@{tasks=@($afterKill.tasks|ForEach-Object {$_.state});workers=@($afterKill.workers).Count;hostFile=$afterKill.hostFile.sha256}
        $out.killedProcesses=@($killed|ForEach-Object {$_.Name+' '+$_.ProcessId})
        $out.setupLogTail=@(Get-Content -LiteralPath $setupLog -Tail 5 -ErrorAction SilentlyContinue|ForEach-Object {[string]$_})
        $watchdog=Get-ScheduledTask -TaskName 'RooIndustriesOptimizationSuite.GovernorSetupWatchdog' -ErrorAction SilentlyContinue
        $out.watchdog=if($watchdog){[ordered]@{state=[string]$watchdog.State;actions=@($watchdog.Actions|ForEach-Object {$_.Arguments});triggers=@($watchdog.Triggers|ForEach-Object {[string]$_.CimClass.CimClassName+' '+$_.StartBoundary})}}else{$null}
        Check ($null -ne $suspended -and $killed.Count -ge 1 -and @($afterKill.workers).Count -eq 0 -and $afterKill.tasks[0].state -eq 'Disabled' -and $null -ne $watchdog) 'Setup was killed right after it stopped the governor; the task is disabled and a recovery task is waiting'
        Check ($afterKill.hostFile.sha256 -eq $before.hostFile.sha256 -and (Test-Path -LiteralPath $hostExe)) 'The killed setup left the installed files unchanged'
        if($probe){Check (Same (Read-Controls $probe) $state.original) 'The stopped governor gave the probe its original values'}
        $back=Wait-Until {$d=Describe-State;$d.hostRunning -eq $true -and (-not $probe -or (Same (Read-Controls $probe) $state.wanted))} 480
        $out.recoveredSecondsAfterKill=if($back){[Math]::Round(([DateTime]::UtcNow-$killedAt).TotalSeconds,1)}else{$null}
        $recovered=Describe-State;$out.recovered=[ordered]@{tasks=@($recovered.tasks|ForEach-Object {$_.state});workers=@($recovered.workers).Count;hostRunning=$recovered.hostRunning}
        Check ($null -ne $back -and $recovered.tasks[0].state -ne 'Disabled') ('The governor came back on its own after the killed setup ('+$out.recoveredSecondsAfterKill+' s) and enforces the rule again')
        Check ($null -eq (Get-ScheduledTask -TaskName 'RooIndustriesOptimizationSuite.GovernorSetupWatchdog' -ErrorAction SilentlyContinue)) 'The recovery task removed itself'
        $out.leftoverSetupFolders=@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'is-*.tmp' -ErrorAction SilentlyContinue|ForEach-Object {$_.Name})
    }
    'kill-setup-rerun' {
        $probe=Get-Probe $state.probePid
        $setupLog=Join-Path $work 'setup-killed-rerun.log'
        Remove-Item -LiteralPath $setupLog -ErrorAction SilentlyContinue
        $setup=Start-Process -FilePath $Installer -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+$setupLog+'"') -PassThru
        $started=[DateTime]::Now.AddSeconds(-2)
        $suspended=Wait-Until {$log=Join-Path $app 'setup\governor-setup.log';(Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).LastWriteTime -ge $started -and ([IO.File]::ReadAllText($log) -match 'Suspend Suspended')} 120
        foreach($process in @(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -eq $setup.Id -or ($_.ExecutablePath -like '*\is-*.tmp\*' -and $_.Name -like 'RooIndustries-OptimizationSuite-*')})){Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}
        Start-Sleep -Seconds 2
        $afterKill=Describe-State;$out.afterKill=[ordered]@{tasks=@($afterKill.tasks|ForEach-Object {$_.state});workers=@($afterKill.workers).Count}
        $rerunLog=Join-Path $work 'setup-rerun.log'
        $rerun=Start-Process -FilePath $Installer -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+$rerunLog+'"') -PassThru -Wait
        $out.rerunExit=$rerun.ExitCode
        $out.rerunLog=@(Get-Content -LiteralPath $rerunLog|Where-Object {$_ -match 'Governor|Suspend|Resume|recovery'}|ForEach-Object {[string]$_})
        $back=Wait-Until {$d=Describe-State;$d.hostRunning -eq $true -and (-not $probe -or (Same (Read-Controls $probe) $state.wanted))} 60
        $s=Describe-State;$out.state=[ordered]@{tasks=@($s.tasks|ForEach-Object {$_.state});hostRunning=$s.hostRunning}
        Check ($null -ne $suspended -and $afterKill.tasks[0].state -eq 'Disabled' -and $rerun.ExitCode -eq 0 -and $null -ne $back -and $s.tasks[0].state -ne 'Disabled') 'Running setup again right after a killed setup brings the governor back and enforces the rule'
        Check ($null -eq (Get-ScheduledTask -TaskName 'RooIndustriesOptimizationSuite.GovernorSetupWatchdog' -ErrorAction SilentlyContinue)) 'No recovery task is left after the second setup'
    }
    'record' {$s=Describe-State;$out.state=$s;Set-StateValue ('record_'+$Phase) $s;Set-StateValue 'recordedHostPid' $s.hostPid;Set-StateValue 'recordedHostFile' $s.hostFile;Set-StateValue 'recordedRules' $s.ruleFiles;Save-State}
    'verify-replaced' {
        $s=Describe-State;$out.state=$s
        Check ($s.hostRunning -eq $true -and $s.hostPid -ne $state.recordedHostPid) 'A new governor worker runs after setup'
        Check ($s.hostFile.createdUtc -ne $state.recordedHostFile.createdUtc) 'Setup deleted and replaced the host files'
        Check ((@($s.ruleFiles|ForEach-Object {$_.sha256}) -join ',') -eq (@($state.recordedRules|ForEach-Object {$_.sha256}) -join ',')) 'Setup kept the saved rules byte for byte'
    }
    'verify-removed' {
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check (@($s.tasks).Count -eq 0) 'Uninstall removed every governor task'
        Check (@($s.workers).Count -eq 0) 'No governor process is left'
        Check (-not (Test-Path -LiteralPath $app)) 'The app folder is gone'
        Check (@($s.ruleFiles|Where-Object {$_.name -eq ($state.ruleId+'.json')}).Count -eq 1) 'Uninstall kept the saved rules'
        $keptMarkers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
        Check (Test-Path -LiteralPath (Join-Path $dataRoot 'operations') -PathType Container) 'Uninstall kept the operations folder with its journals'
        Check ($null -ne $keptMarkers -and $null -ne $keptMarkers.GetValue($dataRoot.ToUpperInvariant())) 'Uninstall kept the data folder protection marker'
        if($probe){Check (Same (Read-Controls $probe) $state.original) 'Uninstall gave the running probe its original 8 controls back'}else{Check $false 'The long-running probe is still alive to verify restoration'}
    }
    'cleanup' {
        Get-Process -Name 'RooIndustriesGovernorProbe' -ErrorAction SilentlyContinue|Stop-Process -Force
        foreach($task in Tasks){Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false}
        foreach($worker in Workers){Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue}
        Start-Sleep -Seconds 1
        if(Test-Path -LiteralPath $policyRoot){Remove-Item -LiteralPath $policyRoot -Recurse -Force}
        Get-ChildItem -LiteralPath $dataRoot -Directory -ErrorAction SilentlyContinue|Where-Object {$_.Name -like 'process-rules.*'}|Remove-Item -Recurse -Force
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        $out.left=[ordered]@{tasks=@(Tasks).Count;workers=@(Workers).Count;policyRoot=(Test-Path -LiteralPath $policyRoot);app=(Test-Path -LiteralPath $app)}
    }
}
$json=$out|ConvertTo-Json -Depth 12
if(Test-Path -LiteralPath $work){[IO.File]::WriteAllText((Join-Path $work ('phase-'+$Phase+'-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'.json')),$json,[Text.UTF8Encoding]::new($false))}
$json
