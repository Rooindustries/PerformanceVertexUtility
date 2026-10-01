function Use-Rule($Rule){
    Save-Rule $Rule|Out-Null
    return Worker 'Sync'
}

function Wait-Field([Diagnostics.Process]$Process,[string]$Field,$Value,[double]$Seconds=10){
    return Wait-Until {[string](Read-Field $Process $Field) -eq [string]$Value} $Seconds
}

function Test-ScenarioPerField {
    $path=Copy-Probe 'RooIndustriesGovernorFixture.exe' 'fixture' 'RooIndustriesGovernorFixture.exe'
    $choice=Get-TopologyChoice (Start-Probe (Copy-Probe))
    $fixture=Start-Probe $path '0 2000 0 900'
    Start-Sleep -Seconds 1
    $before=Read-Controls $fixture
    $rule=New-Rule $path @{cpuPriority='AboveNormal';ioPriority=1;memoryPriority=3} 'Per-field' 'path' $choice.selection
    Use-Rule $rule|Out-Null
    $applied=Wait-Until {$c=Read-Controls $fixture;$c.cpuPriority -eq 'AboveNormal' -and $c.ioPriority -eq 1 -and $c.memoryPriority -eq 3} 10
    Note 'secondsToAllowedFields' $applied
    Assert ($null -ne $applied) 'The fields Windows allows are applied although Windows denies CPU Sets for this app'
    Start-Sleep -Seconds 4
    $now=Read-Controls $fixture
    Note 'controls' ([ordered]@{before=$before;now=$now})
    Assert ($now.cpuPriority -eq 'AboveNormal' -and $now.ioPriority -eq 1 -and $now.memoryPriority -eq 3 -and $now.cpuSets -eq $before.cpuSets) 'The allowed fields stay applied and the denied field is left as it was'
    $state=Get-GovernorState
    $issues=@($state.issues|Where-Object {$_.processId -eq $fixture.Id})
    $records=@($state.instances|Where-Object {$_.process.processId -eq $fixture.Id -and $_.status -notin @('restored','expired')})
    Note 'issues' $issues
    Note 'records' @($records|ForEach-Object {[string]$_.field+' '+$_.status})
    Assert (@($issues|Where-Object {$_.field -eq 'cpuSets' -and $_.kind -eq 'denied'}).Count -ge 1 -and @($issues|Where-Object {$_.field -ne 'cpuSets'}).Count -eq 0) 'Only CPU Sets is reported unavailable, identified by the Windows access-denied code'
    Assert (@($records|Where-Object {$_.status -eq 'active'}).Count -eq 3 -and @($records|Where-Object {$_.field -eq 'cpuSets'}).Count -eq 0) 'Each allowed field has its own active record and the denied field has none'
}

function Test-ScenarioPerFieldRetry {
    $path=Copy-Probe 'RooIndustriesGovernorFixture.exe' 'fixture' 'RooIndustriesGovernorFixture.exe'
    $choice=Get-TopologyChoice (Start-Probe (Copy-Probe))
    $fixture=Start-Probe $path '0 2000 140 1200' -NoWait
    $started=[Diagnostics.Stopwatch]::StartNew()
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Per-field retry' 'path' $choice.selection)|Out-Null
    Assert ($null -ne (Wait-Field $fixture 'cpuPriority' 'AboveNormal')) 'The allowed field is applied while CPU Sets are denied'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 142} 160 1000
    Assert ((Read-Field $fixture 'cpuSets') -eq '') 'CPU Sets are still unchanged when Windows stops denying access after 140 s'
    $applied=Wait-Until {(Read-Field $fixture 'cpuSets') -eq [string]$choice.cpu.id} 330 1000
    Note 'secondsFromStartToCpuSets' $(if($applied){[Math]::Round($started.Elapsed.TotalSeconds,1)}else{$null})
    Assert ($null -ne $applied) 'A field that kept failing for more than two minutes is retried every 5 minutes and applied once Windows allows it'
}

function Test-ScenarioReassert {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal';ioPriority=1} 'Re-assert')|Out-Null
    Assert ($null -ne (Wait-Until {$c=Read-Controls $probe;$c.cpuPriority -eq 'AboveNormal' -and $c.ioPriority -eq 1} 10)) 'The rule is applied'
    $times=@()
    for($round=1;$round -le 3;$round++){
        Set-Field $probe 'cpuPriority' 'Idle'
        $back=Wait-Field $probe 'cpuPriority' 'AboveNormal' 6
        $times+=$back
        Assert ($null -ne $back) ('Another program''s change number '+$round+' is put back')
        Start-Sleep -Milliseconds 500
    }
    Note 'secondsToPutBack' $times
    Set-Field $probe 'cpuPriority' 'Idle'
    Start-Sleep -Seconds 6
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Idle') 'After three put-backs within ten minutes the governor steps back for that field'
    $cpu=@(Get-Open $probe.Id|Where-Object {$_.field -eq 'cpuPriority'})
    Note 'steppedBack' $cpu
    Assert ($cpu.Count -eq 1 -and $cpu[0].status -eq 'conflict' -and $cpu[0].errorKind -eq 'keepsChanging' -and $cpu[0].error -eq 'This app keeps changing it back, so Roo Industries stepped back.') 'The stepped-back field says the app keeps changing it back'
    Set-Field $probe 'ioPriority' 0
    Assert ($null -ne (Wait-Field $probe 'ioPriority' 1 6)) 'The other field of the same app is still enforced'
    Worker 'Pause'|Out-Null
    $after=Read-Controls $probe
    Note 'afterPause' $after
    Assert ($after.cpuPriority -eq 'Normal' -and $after.ioPriority -eq 2) 'Pause puts back the captured originals, including the stepped-back field'
}

function Test-ScenarioRuleEditOrphan {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $rule=New-Rule $path @{cpuPriority='AboveNormal'} 'Orphan'
    Use-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    $rule.name='Orphan renamed'
    Save-Rule $rule|Out-Null
    Start-Sleep -Seconds 40
    $open=@(Get-Open $probe.Id|Where-Object {-not $_.field -or $_.field -eq 'cpuPriority'})
    Note 'afterRename' ([ordered]@{value=(Read-Field $probe 'cpuPriority');open=@($open|ForEach-Object {$_.ruleHash.Substring(0,8)+' '+$_.status})})
    Assert ((Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'Forty seconds after a rule edit the app has the rule''s value, not an old original'
    Assert ($open.Count -eq 1) 'Only one unfinished record controls the field after the edit'
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    $rule.enabled=$false
    Save-Rule $rule|Out-Null
    Start-Sleep -Milliseconds 300
    $rule.enabled=$true
    Save-Rule $rule|Out-Null
    Start-Sleep -Seconds 40
    $open=@(Get-Open $probe.Id|Where-Object {-not $_.field -or $_.field -eq 'cpuPriority'})
    Note 'afterOffOn' ([ordered]@{value=(Read-Field $probe 'cpuPriority');open=@($open|ForEach-Object {$_.ruleHash.Substring(0,8)+' '+$_.status})})
    Assert ((Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'Forty seconds after turning the rule off and on the app has the rule''s value'
    Assert ($open.Count -eq 1) 'Only one unfinished record controls the field after off and on'
}

function Test-ScenarioLockContention {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Lock contention')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $operation=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    Core 'process-preview' @{processId=$probe.Id;controls=@{memoryPriority=3};outputPath=$preview}|Out-Null
    $journal=Join-Path $operation 'journal.json'
    $request=Join-Path $operation 'apply-request.json'
    [IO.File]::WriteAllText($request,(@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$script:policyRoot;confirm=$true;previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $env:ROO_INDUSTRIES_TEST_APPLY_PAUSE_MS='6000'
    try {$apply=Start-Process -FilePath $DotNetPath -ArgumentList ('"'+(Join-Path $hostDirectory 'Optimizer.Host.dll')+'" process-apply "'+$request+'"') -WindowStyle Hidden -PassThru}
    finally {Remove-Item Env:\ROO_INDUSTRIES_TEST_APPLY_PAUSE_MS}
    $script:probes.Add($apply)
    Start-Sleep -Seconds 1
    Set-Field $probe 'cpuPriority' 'Idle'
    $apply.WaitForExit(30000)|Out-Null
    Assert ($apply.HasExited -and $apply.ExitCode -eq 0 -and (Read-Field $probe 'memoryPriority') -eq 3) 'Apply once changes a field the rule does not own while holding the app''s lock for 6 s'
    $back=Wait-Field $probe 'cpuPriority' 'AboveNormal' 8
    Note 'secondsToPutBackAfterLock' $back
    Assert ($null -ne $back) 'After the lock is released the governor puts its value back'
    Assert (@(Get-Records $probe.Id|Where-Object {$_.status -eq 'conflict'}).Count -eq 0) 'The busy lock did not mark the rule as conflicting'
    Set-Field $probe 'cpuPriority' 'Idle'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal' 6)) 'The rule is still enforced afterwards'
    Core 'process-restore' @{journalPath=$journal}|Out-Null
}

function Test-ScenarioCrashAfterRestore {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Crash after restore')
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    Disable-ScheduledTask -TaskName $synced.taskName|Out-Null
    $worker=Get-WorkerProcess
    $worker.Kill();$worker.WaitForExit()
    $record=@(Get-Open $probe.Id)[0]
    $empty=Join-Path $script:scenarioRoot 'unrelated-rules'
    Core 'process-restore' @{journalPath=$record.journalPath} $empty|Out-Null
    $statePath=Join-Path $script:policyRoot 'host.json'
    $state=(Read-RooIndustriesOperationJson $statePath).data
    foreach($instance in @($state.instances|Where-Object {$_.journalPath -eq $record.journalPath})){$instance.status='conflict';$instance.error='Windows did not accept the requested value.'}
    Write-RooIndustriesOperationJson $state $statePath
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal' -and (Read-RooIndustriesOperationJson $record.journalPath).data.status -eq 'restored') 'The journal is restored while the governor record still says conflict, as after a crash between the two writes'
    Enable-ScheduledTask -TaskName $synced.taskName|Out-Null
    Start-ScheduledTask -TaskName $synced.taskName
    $back=Wait-Field $probe 'cpuPriority' 'AboveNormal' 20
    Note 'secondsToReapply' $back
    Assert ($null -ne $back) 'After the restart the governor applies the rule again'
    Assert (@(Get-Records $probe.Id|Where-Object {$_.status -eq 'conflict'}).Count -eq 0) 'No conflict is recorded for the restored journal'
}

function Test-ScenarioClockShift {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Clock shift')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    Start-Sleep -Seconds 4
    $wall=[DateTime]::UtcNow
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $restore={Set-Date -Date ($wall+$clock.Elapsed).ToLocalTime()|Out-Null}.GetNewClosure()
    $script:cleanups.Add($restore)
    try {
        Set-Date -Adjust ([TimeSpan]::FromHours(-1))|Out-Null
        Start-Sleep -Seconds 1
        Set-Field $probe 'cpuPriority' 'Idle'
        $reacted=Wait-Until {(Read-Field $probe 'cpuPriority') -eq 'AboveNormal' -or @(Get-Records $probe.Id|Where-Object {$_.status -eq 'conflict'}).Count -gt 0} 8 200
        Note 'secondsToReactWithClockBackOneHour' $reacted
        Assert ($null -ne $reacted) 'With the clock moved back an hour the governor still notices a changed field within seconds'
        $status=Core 'policy-status'
        Assert ($status.hostRunning -eq $true -and -not $status.error) 'With the clock moved back the governor is still reported as running'
    } finally {& $restore}
    Start-Sleep -Seconds 2
    $status=Core 'policy-status'
    Note 'statusAfterClockRestored' ([ordered]@{running=$status.hostRunning;error=$status.error})
    Assert ($status.hostRunning -eq $true -and -not $status.error) 'When the clock jumps forward again the governor is still reported as running'
}

function Test-ScenarioBusyTick {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Busy tick')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    [IO.File]::WriteAllText((Join-Path $script:policyRoot 'tick-pause.request'),'25000')
    $null=Wait-Until {-not (Test-Path -LiteralPath (Join-Path $script:policyRoot 'tick-pause.request'))} 5
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $reports=New-Object System.Collections.Generic.List[string]
    while($clock.Elapsed.TotalSeconds -lt 24){
        $status=Core 'policy-status'
        if($status.hostRunning -ne $true -or $status.error){$reports.Add([string]([Math]::Round($clock.Elapsed.TotalSeconds,1))+' s: '+$status.hostRunning+' '+$status.error)}
        Start-Sleep -Milliseconds 800
    }
    Note 'notRespondingReports' @($reports)
    Assert ($reports.Count -eq 0) 'During a 25-second check the governor is never reported as not responding'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'The rule stays applied'
}

function Test-ScenarioPinnedHashCache {
    $path=Copy-Probe
    $stream=[IO.File]::Open($path,'Open','ReadWrite')
    try {$stream.SetLength($stream.Length+1500MB)} finally {$stream.Dispose()}
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $rule=New-Rule $path @{cpuPriority='AboveNormal'} 'Pinned executable'
    $rule.executableHash=$hash
    Use-Rule $rule|Out-Null
    $times=@()
    for($index=0;$index -lt 3;$index++){
        $probe=Start-Probe $path
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $null=Wait-Field $probe 'cpuPriority' 'AboveNormal' 20 20
        $times+=[Math]::Round($clock.Elapsed.TotalSeconds,2)
        Start-Sleep -Seconds 2
    }
    Note 'secondsToApplyPinnedExecutable' $times
    Assert ($times[1] -lt 0.8 -and $times[2] -lt 0.8) 'A pinned 1.5 GB executable is hashed once, so later starts get their rules quickly'
}

function Test-ScenarioStaleHeartbeatStart {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Stale heartbeat')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $worker=Get-WorkerProcess
    [RooIndustriesGovernorScenarioOracle]::Suspend($worker.Handle)
    $resume={try {[RooIndustriesGovernorScenarioOracle]::Resume($worker.Handle)} catch {}}.GetNewClosure()
    $script:cleanups.Add($resume)
    Start-Sleep -Seconds 17
    $stale=Core 'policy-status'
    Assert ($stale.hostRunning -eq $true -and $stale.error) 'A suspended governor is reported as not answering'
    $resumer=Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(@"
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class RooIndustriesResumeLater { [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr p); }'
Start-Sleep -Seconds 3
`$p=Get-Process -Id $($worker.Id)
[void][RooIndustriesResumeLater]::NtResumeProcess(`$p.Handle)
"@))) -WindowStyle Hidden -PassThru
    $script:probes.Add($resumer)
    $synced=Worker 'Sync'
    Note 'afterSync' ([ordered]@{before=$worker.Id;after=$synced.worker.state.host.processId;running=$synced.worker.hostRunning;error=$synced.worker.error})
    Assert ($synced.worker.hostRunning -eq $true -and $synced.worker.state.host.processId -eq $worker.Id) 'Start governor waits for another heartbeat instead of restarting a governor that was only slow'
}

function Test-ScenarioRestoreRace {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Restore race')
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $worker=Get-WorkerProcess
    [RooIndustriesGovernorScenarioOracle]::Suspend($worker.Handle)
    $watcher=Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(@"
while(Get-Process -Id $($worker.Id) -ErrorAction SilentlyContinue){Start-Sleep -Milliseconds 20}
Start-ScheduledTask -TaskName '$($synced.taskName)'
"@))) -WindowStyle Hidden -PassThru
    $script:probes.Add($watcher)
    Start-Sleep -Seconds 17
    $env:ROO_INDUSTRIES_TEST_RESTORE_RUN_DELAY_MS='3000'
    $result=$null;$failure=$null
    try {$result=Worker 'Sync'} catch {$failure=$_.Exception.Message} finally {Remove-Item Env:\ROO_INDUSTRIES_TEST_RESTORE_RUN_DELAY_MS}
    $status=Core 'policy-status'
    Note 'restoreRace' ([ordered]@{failure=$failure;running=$status.hostRunning;newWorker=$status.state.host.processId;oldWorker=$worker.Id})
    Assert ($null -eq $failure -and $status.hostRunning -eq $true -and $status.state.host.processId -ne $worker.Id) 'Start governor succeeds when the one-minute restart wins the race for the worker lock'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal' 10)) 'The new governor enforces the rule'
}

function Test-ScenarioRuleReadRetry {
    $pathA=Copy-Probe 'RooIndustriesGovernorProbe.exe' 'a'
    $pathB=Copy-Probe 'RooIndustriesGovernorProbeB.exe' 'b'
    $a=Start-Probe $pathA;$b=Start-Probe $pathB
    Save-Rule (New-Rule $pathA @{cpuPriority='AboveNormal'} 'Rule A')|Out-Null
    $ruleB=New-Rule $pathB @{cpuPriority='BelowNormal'} 'Rule B'
    Use-Rule $ruleB|Out-Null
    Assert ($null -ne (Wait-Until {(Read-Field $a 'cpuPriority') -eq 'AboveNormal' -and (Read-Field $b 'cpuPriority') -eq 'BelowNormal'} 10)) 'Both rules are applied'
    $file=Join-Path $script:policyRoot ('rules\'+$ruleB.ruleId+'.json')
    [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow)
    $hold=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $reverted=New-Object System.Collections.Generic.List[string]
    try {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while($clock.Elapsed.TotalSeconds -lt 5){
            $now=@((Read-Field $a 'cpuPriority'),(Read-Field $b 'cpuPriority'))
            if($now[0] -ne 'AboveNormal' -or $now[1] -ne 'BelowNormal'){$reverted.Add([string]([Math]::Round($clock.Elapsed.TotalSeconds,1))+' s '+($now -join '/'))}
            Start-Sleep -Milliseconds 100
        }
    } finally {$hold.Dispose()}
    Start-Sleep -Seconds 2
    Note 'reverted' @($reverted)
    Assert ($reverted.Count -eq 0) 'While a rule file cannot be read for 5 s no app loses its settings'
    Assert ((Read-Field $a 'cpuPriority') -eq 'AboveNormal' -and (Read-Field $b 'cpuPriority') -eq 'BelowNormal') 'Both rules are still applied afterwards'
}

function Test-ScenarioTickError {
    $path=Copy-Probe
    $first=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Tick error' 'filename')|Out-Null
    Assert ($null -ne (Wait-Field $first 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $worker=Get-WorkerProcess
    $hold=[IO.FileStream]::new((Join-Path $script:policyRoot 'host.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $reverted=New-Object System.Collections.Generic.List[string]
    try {
        $second=Start-Probe $path
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while($clock.Elapsed.TotalSeconds -lt 6){
            if((Read-Field $first 'cpuPriority') -ne 'AboveNormal'){$reverted.Add([string]([Math]::Round($clock.Elapsed.TotalSeconds,1)))}
            Start-Sleep -Milliseconds 100
        }
    } finally {$hold.Dispose()}
    $applied=Wait-Field $second 'cpuPriority' 'AboveNormal' 25
    $worker.Refresh()
    Note 'tickError' ([ordered]@{reverted=@($reverted);secondApplied=$applied;workerAlive=-not $worker.HasExited})
    Assert ($reverted.Count -eq 0) 'While the state file cannot be written the running app keeps its settings'
    Assert (-not $worker.HasExited) 'The governor keeps running through the failed checks'
    Assert ($null -ne $applied) 'The new app gets its rules once the state file can be written again'
}

function Test-ScenarioIdleExit {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $rule=New-Rule $path @{cpuPriority='AboveNormal'} 'Idle exit'
    Use-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $rule.enabled=$false
    Save-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Until {(Core 'policy-status').hostRunning -ne $true} 15 500)) 'The governor exits when no rule is on'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal') 'The app gets its original value back'
    Start-Sleep -Seconds 2
    $state=Join-Path $script:policyRoot 'host.json'
    $stamp=(Get-Item -LiteralPath $state).LastWriteTimeUtc
    Start-Sleep -Seconds 130
    $after=(Get-Item -LiteralPath $state).LastWriteTimeUtc
    Note 'stateWrites' ([ordered]@{before=$stamp.ToString('o');after=$after.ToString('o')})
    Assert ($after -eq $stamp) 'With no rule on, the one-minute restarts exit without rewriting the governor state'
}

function Test-ScenarioPrunedRuntime {
    $path=Copy-Probe
    $long=Start-Probe $path
    $deniedPath=Copy-Probe 'RooIndustriesGovernorProbe.exe' 'denied' 'RooIndustriesGovernorFixture.exe'
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Pruning' 'filename')|Out-Null
    Assert ($null -ne (Wait-Field $long 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $denied=Start-Probe $deniedPath '0 1600 0 8' -NoWait
    for($index=0;$index -lt 20;$index++){Start-Probe $path '2' -NoWait|Out-Null;Start-Sleep -Milliseconds 400}
    $null=Wait-Until {$denied.HasExited} 20
    Start-Sleep -Seconds 8
    $beat=Get-Heartbeat
    Note 'diagnostics' $(if($beat){$beat.diagnostics}else{$null})
    Assert ($null -ne $beat -and $beat.diagnostics.watched -le 1 -and $beat.diagnostics.gates -le 1 -and $beat.diagnostics.retries -eq 0 -and $beat.diagnostics.ruleChecks -le 1) 'Per-process tracking and retry entries are dropped when the processes exit'
}

function Test-ScenarioExcluded {
    $path=Copy-Probe 'Wispr Flow.exe' 'excluded'
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Excluded app')|Out-Null
    Start-Sleep -Seconds 4
    $first=Get-Heartbeat
    Start-Sleep -Seconds 12
    $second=Get-Heartbeat
    $issues=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $probe.Id})
    Note 'excluded' ([ordered]@{opensBefore=$(if($first){$first.diagnostics.processOpens});opensAfter=$(if($second){$second.diagnostics.processOpens});issues=$issues})
    Assert ($null -ne $first -and $null -ne $second -and $second.diagnostics.processOpens -eq $first.diagnostics.processOpens) 'An app on the protection list is not opened again and again'
    Assert ($issues.Count -ge 1 -and $issues[0].kind -eq 'excluded' -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'It is reported as excluded and left unchanged'
}

function Test-ScenarioRetryRestore {
    $path=Copy-Probe 'RooIndustriesGovernorFixture.exe' 'fixture' 'RooIndustriesGovernorFixture.exe'
    $fixture=Start-Probe $path '8 1600 30 600' -NoWait
    $started=[Diagnostics.Stopwatch]::StartNew()
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Retry restore')|Out-Null
    Assert ($null -ne (Wait-Field $fixture 'cpuPriority' 'AboveNormal' 6)) 'The rule is applied before the app starts denying access'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 10} 15 500
    Worker 'Pause'|Out-Null
    $stuck=@(Get-Open $fixture.Id)
    Note 'afterPause' @($stuck|ForEach-Object {[string]$_.field+' '+$_.status+' '+$_.errorKind})
    Assert ($stuck.Count -eq 1 -and $stuck[0].status -eq 'conflict' -and $stuck[0].errorKind -eq 'denied' -and (Read-Field $fixture 'cpuPriority') -eq 'AboveNormal') 'Pause cannot put the setting back while the app denies access and keeps the record'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 40} 45 500
    Core 'policy-run' @{durationSeconds=0}|Out-Null
    $after=@(Get-Open $fixture.Id)
    Note 'afterRetry' ([ordered]@{value=(Read-Field $fixture 'cpuPriority');open=$after.Count})
    Assert ((Read-Field $fixture 'cpuPriority') -eq 'Normal' -and $after.Count -eq 0) 'Put settings back restores the record once the app allows access again'
}

function Test-ScenarioPidReuse {
    $deniedPath=Copy-Probe 'RooIndustriesGovernorReuse.exe' 'denied' 'RooIndustriesGovernorFixture.exe'
    $plainPath=Copy-Probe 'RooIndustriesGovernorReuse.exe' 'plain'
    Use-Rule (New-Rule $deniedPath @{cpuPriority='AboveNormal'} 'PID reuse' 'filename')|Out-Null
    $denied=Start-Probe $deniedPath '0 1600 0 900' -NoWait
    $reused=$denied.Id
    $started=[Diagnostics.Stopwatch]::StartNew()
    $null=Wait-Until {@((Get-GovernorState).issues|Where-Object {$_.processId -eq $reused}).Count -gt 0} 15 500
    Assert (@((Get-GovernorState).issues|Where-Object {$_.processId -eq $reused}).Count -ge 1) 'The app that denies access is reported unavailable'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 130} 140 1000
    $pausedAt=[Diagnostics.Stopwatch]::StartNew()
    [IO.File]::WriteAllText((Join-Path $script:policyRoot 'tick-pause.request'),'25000')
    $consumed=Wait-Until {-not (Test-Path -LiteralPath (Join-Path $script:policyRoot 'tick-pause.request'))} 5 20
    Assert ($null -ne $consumed) 'The governor is inside a check that lasts 25 seconds'
    $pausedAt.Restart()
    $denied.Kill();$denied.WaitForExit();$denied.Dispose()
    $found=$null;$tries=0
    $search=[Diagnostics.Stopwatch]::StartNew()
    while($null -eq $found -and $search.Elapsed.TotalSeconds -lt 18){
        $tries++
        $info=[Diagnostics.ProcessStartInfo]::new($plainPath,'3600')
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $candidate=[Diagnostics.Process]::Start($info)
        if($candidate.Id -eq $reused){$found=$candidate;$script:probes.Add($candidate)}
        else {try {$candidate.Kill();$candidate.WaitForExit()} catch {};$candidate.Dispose()}
    }
    Note 'reuse' ([ordered]@{processId=$reused;tries=$tries;seconds=[Math]::Round($search.Elapsed.TotalSeconds,1)})
    Assert ($null -ne $found) 'A new app with the same file name was given the process ID of the one that denied access'
    $applied=Wait-Until {[string](Read-Field $found 'cpuPriority') -eq 'AboveNormal'} 40 100
    $sincePause=$pausedAt.Elapsed.TotalSeconds
    Note 'secondsFromCheckStartToApply' $(if($null -ne $applied){[Math]::Round($sincePause,1)}else{$null})
    Assert ($null -ne $applied -and $sincePause -le 31) 'The new app gets its rules as soon as the check ends, not after the old app''s retry delay'
}

function Test-ScenarioTopologyChanged {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $rule=New-Rule $path @{cpuPriority='AboveNormal';affinity=@{group=0;mask='0x3'}} 'Topology changed'
    $rule.affinityTopologyHash=('A'*64)
    $before=Read-Field $probe 'affinity'
    Use-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'A rule whose saved CPU topology no longer matches still applies its other fields'
    Start-Sleep -Seconds 3
    $issues=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $probe.Id})
    Note 'topologyIssues' $issues
    Assert ((Read-Field $probe 'affinity') -eq $before) 'The affinity is left as it was'
    Assert (@($issues|Where-Object {$_.field -eq 'affinity' -and $_.kind -eq 'topology'}).Count -ge 1 -and @($issues|Where-Object {$_.field -ne 'affinity'}).Count -eq 0) 'Only the affinity is reported as needing review'
}

function Test-ScenarioRuleFileUnreadable {
    $pathA=Copy-Probe 'RooIndustriesGovernorProbe.exe' 'a'
    $pathB=Copy-Probe 'RooIndustriesGovernorProbeB.exe' 'b'
    $a=Start-Probe $pathA;$b=Start-Probe $pathB
    Save-Rule (New-Rule $pathA @{cpuPriority='AboveNormal'} 'Rule A')|Out-Null
    $ruleB=New-Rule $pathB @{cpuPriority='BelowNormal'} 'Rule B'
    Use-Rule $ruleB|Out-Null
    Assert ($null -ne (Wait-Until {(Read-Field $a 'cpuPriority') -eq 'AboveNormal' -and (Read-Field $b 'cpuPriority') -eq 'BelowNormal'} 10)) 'Both rules are applied'
    $file=Join-Path $script:policyRoot ('rules\'+$ruleB.ruleId+'.json')
    $good=[IO.File]::ReadAllBytes($file)
    [IO.File]::WriteAllText($file,'{"schemaVersion":1,"ruleId":',[Text.UTF8Encoding]::new($false))
    $lost=New-Object System.Collections.Generic.List[string]
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt 18){
        $value=[string](Read-Field $a 'cpuPriority')
        if($value -ne 'AboveNormal'){$lost.Add([string]([Math]::Round($clock.Elapsed.TotalSeconds,1))+' s '+$value)}
        Start-Sleep -Milliseconds 100
    }
    Note 'ruleALost' @($lost)
    Assert ($lost.Count -eq 0) 'While another rule file is damaged, the rule that can be read keeps its app set for longer than the read grace period'
    $later=Start-Probe $pathA
    Assert ($null -ne (Wait-Field $later 'cpuPriority' 'AboveNormal' 8)) 'A new app for the readable rule still gets its settings'
    $summary=Core 'policy-summary'
    $state=Get-GovernorState
    Note 'damaged' ([ordered]@{unreadableRules=$summary.unreadableRules;rulesError=$summary.rulesError;rules=$summary.rules;errors=$state.errors;status=$state.status})
    Assert (@($summary.unreadableRules).Count -eq 1 -and @($summary.unreadableRules)[0] -like ('*'+$ruleB.ruleId+'.json*') -and -not $summary.rulesError -and $state.status -eq 'running') 'The damaged file is named and the governor keeps running'
    Assert ((Read-Field $b 'cpuPriority') -eq 'Normal') 'The app of the damaged rule is given its original setting back'
    Worker 'Pause'|Out-Null
    $resumed=$null;$resumeError=$null
    try {$resumed=Worker 'Resume'} catch {$resumeError=$_.Exception.Message}
    Note 'resumeWithDamagedFile' ([ordered]@{error=$resumeError;running=$(if($resumed){$resumed.worker.hostRunning})})
    Assert ($null -eq $resumeError -and $resumed.worker.hostRunning -eq $true) 'Start governor works while one rule file is damaged'
    Assert ($null -ne (Wait-Field $a 'cpuPriority' 'AboveNormal' 25)) 'The readable rule is applied again after the restart'
    $ruleA=@(Core 'rules-list'|Where-Object {$_.name -eq 'Rule A'})[0]
    $ruleA.enabled=$false
    $off=$null;$offError=$null
    try {$off=Save-Rule $ruleA} catch {$offError=$_.Exception.Message}
    Assert ($null -eq $offError) 'A rule can be turned off while another rule file is damaged'
    $ruleA.enabled=$true
    $on=$null;$onError=$null
    try {$on=Save-Rule $ruleA} catch {$onError=$_.Exception.Message}
    $pathC=Copy-Probe 'RooIndustriesGovernorProbeC.exe' 'c'
    $added=$null;$addError=$null
    try {$added=Save-Rule (New-Rule $pathC @{ioPriority=1} 'Rule C')} catch {$addError=$_.Exception.Message}
    Note 'editsWhileDamaged' ([ordered]@{turnOn=$onError;addRule=$addError})
    Assert ($null -eq $onError -and $null -eq $addError) 'Rules can be turned on and added while another rule file is damaged'
    $c=Start-Probe $pathC
    $operation=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    $journal=Join-Path $operation 'journal.json'
    $unrelated=$null;$unrelatedError=$null
    try {
        Core 'process-preview' @{processId=$c.Id;controls=@{memoryPriority=3};outputPath=$preview}|Out-Null
        $unrelated=Core 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal}
    } catch {$unrelatedError=$_.Exception.Message}
    Note 'applyOnceWhileDamaged' ([ordered]@{error=$unrelatedError;status=$(if($unrelated){$unrelated.status})})
    Assert ($null -eq $unrelatedError -and $unrelated.status -eq 'applied' -and (Read-Field $c 'memoryPriority') -eq 3) 'Apply once still works on a setting no readable rule owns while a rule file is damaged'
    Core 'process-restore' @{journalPath=$journal}|Out-Null
    [IO.File]::WriteAllBytes($file,$good)
    Assert ($null -ne (Wait-Field $b 'cpuPriority' 'BelowNormal' 10)) 'Once the file can be read again its rule applies again'
}

function Test-ScenarioPinnedUnreadable {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $rule=New-Rule $path @{cpuPriority='AboveNormal'} 'Pinned unreadable'
    $rule.executableHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $script:pinnedPath=$path
    $script:cleanups.Add({Set-ClaimsReadDenied $script:pinnedPath $false})
    Set-ClaimsReadDenied $path $true
    Use-Rule $rule|Out-Null
    Start-Sleep -Seconds 15
    $beat=Get-Heartbeat
    $issues=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $probe.Id})
    Note 'pinnedUnreadable' ([ordered]@{hashAttempts=$(if($beat){$beat.diagnostics.hashAttempts});issues=$issues})
    Assert ($null -ne $beat -and $beat.diagnostics.hashAttempts -ge 1 -and $beat.diagnostics.hashAttempts -le 7) 'A pinned executable the governor cannot read is retried with growing delays, not on every check'
    Assert ($issues.Count -ge 1 -and $issues[0].kind -eq 'error' -and $issues[0].message -like '*could not be read to check it*' -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'It is reported as unreadable and the app is left unchanged'
    Set-ClaimsReadDenied $path $false
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal' 80)) 'Once the file can be read again the rule applies'
}

function Test-ScenarioDeniedLookups {
    $deniedPath=Copy-Probe 'RooIndustriesGovernorProbe.exe' 'denied' 'RooIndustriesGovernorFixture.exe'
    $denied=Start-Probe $deniedPath '0 1600 0 900' -NoWait
    Start-Sleep -Seconds 2
    Use-Rule (New-Rule $deniedPath @{cpuPriority='AboveNormal'} 'Denied lookups' 'filename')|Out-Null
    Start-Sleep -Seconds 45
    $beat=Get-Heartbeat
    Note 'ownerLookups' $(if($beat){$beat.diagnostics.ownerLookups})
    Assert ($null -ne $beat -and $beat.diagnostics.ownerLookups -eq 1) 'The owner of an app that denies access is looked up once, not at every retry'
}

function Test-ScenarioConflictHoldsField {
    $path=Copy-Probe 'RooIndustriesGovernorFixture.exe' 'fixture' 'RooIndustriesGovernorFixture.exe'
    $fixture=Start-Probe $path '12 1600 30 600' -NoWait
    $started=[Diagnostics.Stopwatch]::StartNew()
    $rule=New-Rule $path @{cpuPriority='AboveNormal'} 'Conflict holds'
    Use-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Field $fixture 'cpuPriority' 'AboveNormal' 6)) 'The rule is applied before the app starts denying access'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 14} 18 500
    $rule.enabled=$false
    Save-Rule $rule|Out-Null
    Worker 'Pause'|Out-Null
    $stuck=@(Get-Open $fixture.Id)
    Assert ($stuck.Count -eq 1 -and $stuck[0].status -eq 'conflict') 'With the rule off and the app denying access the record is kept as a failed restore'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 46} 50 500
    $operation=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    Core 'process-preview' @{processId=$fixture.Id;controls=@{cpuPriority='Idle'};outputPath=$preview}|Out-Null
    $refusal=$null
    try {Core 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=(Join-Path $operation 'journal.json')}|Out-Null} catch {$refusal=$_.Exception.Message}
    Note 'applyOnceWhileHeld' $refusal
    Assert ($refusal -like '*Managed by the governor: cpuPriority*' -and (Read-Field $fixture 'cpuPriority') -eq 'AboveNormal') 'Apply once cannot take a field the governor still has to put back'
    Core 'policy-run' @{durationSeconds=0}|Out-Null
    Assert ((Read-Field $fixture 'cpuPriority') -eq 'Normal' -and @(Get-Open $fixture.Id).Count -eq 0) 'The pending restore then puts back the original value'
}

function Set-ScenarioListDenied([string]$Path,[bool]$Denied){
    $directory=[IO.DirectoryInfo]::new($Path)
    $security=$directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.FileSystemRights]::ListDirectory,[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
    if($Denied){$security.AddAccessRule($rule)}else{[void]$security.RemoveAccessRule($rule)}
    $directory.SetAccessControl($security)
}

function Test-ScenarioConfigErrorRestoreBackoff {
    $path=Copy-Probe 'RooIndustriesGovernorFixture.exe' 'fixture' 'RooIndustriesGovernorFixture.exe'
    $fixture=Start-Probe $path '12 1600 32 600' -NoWait
    $started=[Diagnostics.Stopwatch]::StartNew()
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Config error backoff')|Out-Null
    Assert ($null -ne (Wait-Field $fixture 'cpuPriority' 'AboveNormal' 6)) 'The rule is applied before the app starts denying access'
    $rules=Join-Path $script:policyRoot 'rules'
    $script:deniedRules=$rules
    $script:cleanups.Add({Set-ScenarioListDenied $script:deniedRules $false})
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 14} 18 500
    Set-ScenarioListDenied $rules $true
    $configError=Wait-Until {(Get-GovernorState).status -eq 'configurationError'} 30 500
    Note 'secondsToConfigurationError' $(if($configError){[Math]::Round($configError,1)})
    Assert ($null -ne $configError) 'With the rules folder unreadable the governor reports a configuration error after its grace period'
    $null=Wait-Until {$started.Elapsed.TotalSeconds -ge 49} 55 500
    $stillHeld=[string](Read-Field $fixture 'cpuPriority')
    Note 'fiveSecondsAfterDenialEnded' $stillHeld
    Assert ($stillHeld -eq 'AboveNormal') 'Restores that keep failing are retried with growing delays, not every half second'
    $restored=Wait-Until {(Read-Field $fixture 'cpuPriority') -eq 'Normal'} 30 500
    Note 'secondsToRestore' $(if($restored){[Math]::Round($restored,1)})
    Assert ($null -ne $restored) 'The setting is put back once a retry succeeds'
    Set-ScenarioListDenied $rules $false
    Assert ($null -ne (Wait-Until {(Get-GovernorState).status -eq 'running'} 20 500)) 'The governor goes back to running once the rules can be read'
}
