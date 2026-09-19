param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-policy-worker-'+[Guid]::NewGuid().ToString('N'))
$hostDirectory=Join-Path $root 'host'
$probeDirectory=Join-Path $root 'probe'
$policyRoot=Join-Path $root 'saved rules'
$probe=$null;$taskName=$null
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
function Worker([string]$WorkerAction){
    $text=@(& (Join-Path $PSScriptRoot 'Invoke-ProcessPolicyWorker.ps1') -Action $WorkerAction -PolicyRoot $policyRoot -DotNetPath $DotNetPath -HostDirectory $hostDirectory -ConfirmApply) -join "`n"
    return ($text|ConvertFrom-Json).data
}
function Core([string]$CoreAction,[object]$Values){
    $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$policyRoot;confirm=$true}
    foreach($key in $Values.Keys){$request[$key]=$Values[$key]}
    $path=Join-Path $root 'request.json'
    Write-RooIndustriesOperationJson $request $path
    $result=(@(& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $CoreAction $path) -join "`n")|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw $result.error.message}
    return $result.data
}
function Start-Probe {
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $probeDirectory 'OptimizerCore.exe'),'--probe')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    return [Diagnostics.Process]::Start($info)
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesPolicyWorkerOracle {
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr process, int kind, out uint value, uint size);
    public static uint Memory(IntPtr process) { uint value; if(!GetProcessInformation(process,0,out value,4)) throw new System.ComponentModel.Win32Exception(); return value; }
}
'@
try {
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $hostDirectory | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Policy host publish failed.'}
    & $DotNetPath publish (Join-Path $repoRoot 'tools\validation\OptimizerCore\OptimizerCore.csproj') -c Release --self-contained false -o $probeDirectory | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Disposable process publish failed.'}
    $probe=Start-Probe
    $original=[RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle)
    $desired=if($original -eq 2){3}else{2}
    $rule=@{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=(Get-RooIndustriesOperationOwner);name='Disposable worker validation';enabled=$true;
        matchMode='path';executablePath=$probe.MainModule.FileName;executableHash=$null;controls=@{memoryPriority=$desired};cpuSelection=$null}
    Core 'rule-save' @{rule=$rule}|Out-Null
    $started=Worker 'Start';$taskName=$started.taskName
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while([RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle) -ne $desired -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 100}
    Assert ($started.worker.hostRunning -and [RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle) -eq $desired) 'A separate scheduled worker applies saved rules after its launcher returns'
    $hostIdentity=$started.worker.state.host
    $repeated=Worker 'Start'
    Assert ($repeated.worker.state.host.processId -eq $hostIdentity.processId -and $repeated.worker.state.host.creationTimeFileTimeUtc -eq $hostIdentity.creationTimeFileTimeUtc) 'Repeated start retains one worker instance'
    Assert (-not $started.runAtLogon -and -not $repeated.runAtLogon) 'Starting a worker does not implicitly enable sign-in startup'
    $probe.Kill();$probe.WaitForExit();$probe.Dispose();$probe=Start-Probe
    $original=[RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle)
    $clock.Restart()
    while([RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle) -ne $desired -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 100}
    Assert ([RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle) -eq $desired) 'The detached worker discovers a relaunched process without the desktop app'
    $logon=Worker 'EnableLogon'
    $task=Get-ScheduledTask -TaskName $taskName
    $triggerUser=$task.Triggers[0].UserId
    $triggerSid=if($triggerUser -match '^S-1-'){[string]$triggerUser}else{[Security.Principal.NTAccount]::new($triggerUser).Translate([Security.Principal.SecurityIdentifier]).Value}
    Write-Output ('Task trigger user: '+$triggerSid+'; execution limit: '+$task.Settings.ExecutionTimeLimit+'; enabled: '+$logon.runAtLogon)
    Assert ($logon.runAtLogon -and $triggerSid -eq (Get-RooIndustriesOperationOwner).userSid -and $task.Settings.ExecutionTimeLimit -eq 'PT0S') 'Sign-in registration is bound to the current user and has no execution time limit'
    Assert (-not (Worker 'DisableLogon').runAtLogon) 'Sign-in startup can be disabled without deleting saved rules'
    $workerProcess=Get-Process -Id $hostIdentity.processId
    Assert ($workerProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $hostIdentity.creationTimeFileTimeUtc) 'Crash testing is restricted to the exact disposable worker instance'
    $workerProcess.Kill();$workerProcess.WaitForExit();$workerProcess.Dispose()
    $stale=Core 'policy-status' @{}
    Assert ($stale.hostRunning -eq $false -and $stale.state.status -eq 'running') 'Live identity checks distinguish a dead worker from a stale running record'
    $recovered=Worker 'Stop'
    Assert (-not $recovered.worker.hostRunning -and [RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle) -eq $original) 'Stopping an interrupted worker recovers and verifies its still-owned original controls'
    Worker 'Start'|Out-Null
    $stopped=Worker 'Stop'
    Assert (-not $stopped.worker.hostRunning -and [RooIndustriesPolicyWorkerOracle]::Memory($probe.Handle) -eq $original) 'Normal worker shutdown completes restoration before reporting stopped'
} finally {
    if(Test-Path -LiteralPath (Join-Path $hostDirectory 'Optimizer.Host.dll')){Worker 'Remove'|Out-Null}
    if($probe){if(-not $probe.HasExited){$probe.Kill()};$probe.WaitForExit();$probe.Dispose()}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root) -and ($null -eq $taskName -or -not(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))) 'Worker validation removes its scheduled task, processes and temporary state'
