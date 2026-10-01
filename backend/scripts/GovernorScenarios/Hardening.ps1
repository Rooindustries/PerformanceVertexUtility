function ConvertTo-HardeningUtc($Value){
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    return [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Assert-HardeningRefused([scriptblock]$Action,[string]$Expected,[string]$Message){
    $text=$null
    try {& $Action|Out-Null} catch {$text=$_.Exception.Message}
    Note ('refusal: '+$Message) $text
    Assert ($null -ne $text -and $text -like ('*'+$Expected+'*')) $Message
}

function Suspend-HardeningWorker([Diagnostics.Process]$Worker){
    [RooIndustriesGovernorScenarioOracle]::Suspend($Worker.Handle)
    $script:cleanups.Add({try {[RooIndustriesGovernorScenarioOracle]::Resume($Worker.Handle)} catch {}}.GetNewClosure())
}

function Test-ScenarioSaveWaitsForRulesLock {
    Save-Rule (New-Rule (Copy-Probe 'RooIndustriesGovernorLockSeed.exe' 'seed') @{cpuPriority='AboveNormal'} 'Seed rule')|Out-Null
    $first=New-Rule (Copy-Probe 'RooIndustriesGovernorLockFirst.exe' 'first') @{cpuPriority='BelowNormal'} 'First rule'
    $second=New-Rule (Copy-Probe 'RooIndustriesGovernorLockSecond.exe' 'second') @{ioPriority=1} 'Second rule'
    $lock=Join-Path $script:policyRoot 'rules-write.lock'
    $firstCall=Invoke-HostLater 'rule-save' @{rule=$first} @{ROO_INDUSTRIES_TEST_LOCKED_PAUSE_MS='6000'}
    $held=Wait-Until {Test-Path -LiteralPath $lock} 30 20
    Assert ($null -ne $held) 'The first save is holding the rules lock inside its pause'
    $secondCall=Invoke-HostLater 'rule-save' @{rule=$second}
    $firstResult=Read-HostLater $firstCall
    $secondResult=Read-HostLater $secondCall
    $firstSeconds=($firstCall.process.ExitTime-$firstCall.process.StartTime).TotalSeconds
    $secondSeconds=($secondCall.process.ExitTime-$secondCall.process.StartTime).TotalSeconds
    $names=@(Core 'rules-list'|ForEach-Object {$_.name})
    Note 'saveWaitsForRulesLock' ([ordered]@{first=$firstResult.status;firstError=$firstResult.error.message;firstSeconds=[Math]::Round($firstSeconds,1);second=$secondResult.status;secondError=$secondResult.error.message;secondSeconds=[Math]::Round($secondSeconds,1);rules=$names})
    Assert ($firstSeconds -ge 5) 'The pause really kept the first save inside the rules lock for about six seconds'
    Assert ($secondResult.status -eq 'completed') 'A second save that arrives while the first holds the rules lock completes instead of failing'
    Assert ($secondSeconds -ge 3) 'The second save waited for the first one to release the lock'
    Assert ($firstResult.status -eq 'completed' -and (Test-Path -LiteralPath (Join-Path $script:policyRoot ('rules\'+$first.ruleId+'.json'))) -and (Test-Path -LiteralPath (Join-Path $script:policyRoot ('rules\'+$second.ruleId+'.json')))) 'Both rule files exist'
    Assert ($names -contains 'First rule' -and $names -contains 'Second rule') 'Both rules are listed'
}

function Test-ScenarioSaveLockWaitBounded {
    Save-Rule (New-Rule (Copy-Probe 'RooIndustriesGovernorBoundSeed.exe' 'seed') @{cpuPriority='AboveNormal'} 'Seed rule')|Out-Null
    $rule=New-Rule (Copy-Probe 'RooIndustriesGovernorBound.exe' 'bound') @{cpuPriority='BelowNormal'} 'Bounded wait'
    $lock=Join-Path $script:policyRoot 'rules-write.lock'
    $hold=[IO.FileStream]::new($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
    $script:cleanups.Add({try {$hold.Dispose()} catch {}}.GetNewClosure())
    $call=Invoke-HostLater 'rule-save' @{rule=$rule}
    $result=Read-HostLater $call
    $seconds=($call.process.ExitTime-$call.process.StartTime).TotalSeconds
    Note 'saveLockWaitBounded' ([ordered]@{status=$result.status;error=$result.error.message;seconds=[Math]::Round($seconds,1)})
    Assert ($result.status -eq 'failed' -and $result.error.message -like '*Another rule change is still running. Try again in a moment.*') 'A save that cannot get the rules lock says another rule change is still running'
    Assert ($seconds -ge 44 -and $seconds -lt 58) 'The save waited about 45 seconds for the lock before giving up'
    Assert (-not (Test-Path -LiteralPath (Join-Path $script:policyRoot ('rules\'+$rule.ruleId+'.json')))) 'The refused rule was not saved'
    $hold.Dispose()
    $saved=Save-Rule $rule
    Assert ($null -ne $saved -and (Test-Path -LiteralPath (Join-Path $script:policyRoot ('rules\'+$rule.ruleId+'.json'))) -and -not (Test-Path -LiteralPath $lock)) 'Once the lock is free the same save works and leaves no lock behind'
}

function Test-ScenarioHeartbeatLeftovers {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Save-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Heartbeat leftovers')|Out-Null
    $old=@(1..3|ForEach-Object {Join-Path $script:policyRoot ('heartbeat.json.'+[Guid]::NewGuid().ToString('N')+'.tmp')})
    $fresh=Join-Path $script:policyRoot ('heartbeat.json.'+[Guid]::NewGuid().ToString('N')+'.tmp')
    $notGuid=Join-Path $script:policyRoot 'heartbeat.json.not-a-guid.tmp'
    $other=Join-Path $script:policyRoot ('host.json.'+[Guid]::NewGuid().ToString('N')+'.tmp')
    foreach($file in $old+@($notGuid,$other)){
        [IO.File]::WriteAllText($file,'{"torn":',[Text.UTF8Encoding]::new($false))
        [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow.AddMinutes(-10))
    }
    [IO.File]::WriteAllText($fresh,'{"torn":',[Text.UTF8Encoding]::new($false))
    Worker 'Sync'|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal' 15)) 'The rule is applied'
    $first=$null
    $null=Wait-Until {$script:beat=Get-Heartbeat;$null -ne $script:beat} 15
    $first=$script:beat
    Assert ($null -ne $first) 'The governor writes a heartbeat'
    $advanced=Wait-Until {$latest=Get-Heartbeat;$null -ne $latest -and [int64]$latest.tick -gt [int64]$first.tick} 10
    $second=$null
    $null=Wait-Until {$script:beat=Get-Heartbeat;$null -ne $script:beat -and [int64]$script:beat.tick -gt [int64]$first.tick+3000} 12
    $second=$script:beat
    $left=@(Get-ChildItem -LiteralPath $script:policyRoot -File -Filter 'heartbeat.json.*.tmp'|ForEach-Object {$_.FullName})
    Note 'heartbeatLeftovers' ([ordered]@{left=@($left|ForEach-Object {Split-Path $_ -Leaf});firstTick=$first.tick;secondTick=$(if($second){$second.tick})})
    Assert (@($old|Where-Object {Test-Path -LiteralPath $_}).Count -eq 0) 'Heartbeat temporary files older than a minute are removed when the governor starts'
    Assert ((Test-Path -LiteralPath $fresh) -and (Test-Path -LiteralPath $notGuid) -and (Test-Path -LiteralPath $other)) 'A new temporary file, a file that is not a heartbeat temporary and another file''s temporary are left alone'
    Assert ($left.Count -eq 2) 'The heartbeat does not leave temporary files of its own beside the two that were kept'
    Assert ($null -ne $advanced -and $null -ne $second -and [int64]$second.tick -gt [int64]$first.tick+3000) 'The heartbeat keeps advancing every few seconds'
    $status=Core 'policy-status'
    Assert ($status.hostRunning -eq $true -and -not $status.error) 'The status reader accepts the heartbeat file as written'
}

function Test-ScenarioSleepGap {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Sleep gap')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $worker=Get-WorkerProcess
    $discount=Join-Path $script:policyRoot 'clock-discount.request'
    Suspend-HardeningWorker $worker
    Start-Sleep -Seconds 17
    $control=Core 'policy-status'
    Note 'frozenWithoutDiscount' ([ordered]@{running=$control.hostRunning;error=$control.error})
    Assert ($control.hostRunning -eq $true -and [string]$control.error -like '*heartbeat is stale*') 'Control: a governor frozen for 17 seconds is reported as not answering when the clock counts all of that time'
    [RooIndustriesGovernorScenarioOracle]::Resume($worker.Handle)
    Assert ($null -ne (Wait-Until {$s=Core 'policy-status';$s.hostRunning -eq $true -and -not $s.error} 15 300)) 'Control: the heartbeat resumes after the freeze'
    $before=$null
    $null=Wait-Until {$script:beat=Get-Heartbeat;$null -ne $script:beat} 10
    $before=$script:beat
    $frozen=[Diagnostics.Stopwatch]::StartNew()
    [RooIndustriesGovernorScenarioOracle]::Suspend($worker.Handle)
    Start-Sleep -Seconds 17
    $frozenMs=[int]$frozen.ElapsedMilliseconds
    [IO.File]::WriteAllText($discount,[string]($frozenMs-1500),[Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 500
    $gap=Core 'policy-status'
    Note 'frozenWithDiscount' ([ordered]@{frozenMs=$frozenMs;discountMs=($frozenMs-1500);running=$gap.hostRunning;error=$gap.error})
    Assert ($gap.hostRunning -eq $true -and -not $gap.error) 'After a gap of 17 seconds of which the unbiased clock counted only about 1.5 seconds the governor is not reported as not answering'
    [RooIndustriesGovernorScenarioOracle]::Resume($worker.Handle)
    $reports=New-Object System.Collections.Generic.List[string]
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt 6){
        $status=Core 'policy-status'
        if($status.hostRunning -ne $true -or $status.error){$reports.Add([string]([Math]::Round($clock.Elapsed.TotalSeconds,1))+' s: '+$status.hostRunning+' '+$status.error)}
        Start-Sleep -Milliseconds 300
    }
    Note 'reportsAfterWake' @($reports)
    Assert ($reports.Count -eq 0) 'Right after the gap the governor is never reported as not answering'
    $after=$null
    $null=Wait-Until {$script:beat=Get-Heartbeat;$null -ne $script:beat -and [int64]$script:beat.tick -gt [int64]$before.tick} 10
    $after=$script:beat
    Assert ($null -ne $after -and [int64]$after.tick -gt [int64]$before.tick) 'The heartbeat clock moved forward across the gap'
    Set-Field $probe 'cpuPriority' 'Idle'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal' 15)) 'The rule is still enforced after the gap'
}

function Test-ScenarioHostStateUnknownStatus {
    $pathA=Copy-Probe 'RooIndustriesGovernorStatusA.exe' 'a'
    $pathB=Copy-Probe 'RooIndustriesGovernorStatusB.exe' 'b'
    $pathC=Copy-Probe 'RooIndustriesGovernorStatusC.exe' 'c'
    $a=Start-Probe $pathA;$b=Start-Probe $pathB;$c=Start-Probe $pathC
    Save-Rule (New-Rule $pathA @{cpuPriority='AboveNormal'} 'Status A')|Out-Null
    $synced=Use-Rule (New-Rule $pathB @{cpuPriority='AboveNormal'} 'Status B')
    Assert ($null -ne (Wait-Until {(Read-Field $a 'cpuPriority') -eq 'AboveNormal' -and (Read-Field $b 'cpuPriority') -eq 'AboveNormal'} 15)) 'Both rules are applied'
    $statePath=Join-Path $script:policyRoot 'host.json'
    $log=Join-Path $script:policyRoot 'logs\governor.log'
    $script:cleanups.Add({
        try {
            $repair=(Read-RooIndustriesOperationJson $statePath).data
            foreach($instance in @($repair.instances|Where-Object {$_.status -eq 'weird'})){$instance.status='expired'}
            Write-RooIndustriesOperationJson $repair $statePath
        } catch {}
    }.GetNewClosure())
    Disable-ScheduledTask -TaskName $synced.taskName|Out-Null
    $worker=Get-WorkerProcess
    $worker.Kill();$worker.WaitForExit()
    $state=(Read-RooIndustriesOperationJson $statePath).data
    $count=@($state.instances).Count
    $weird=@($state.instances|Where-Object {$_.process.processId -eq $b.Id})[0]
    $weird.status='weird'
    Write-RooIndustriesOperationJson $state $statePath
    Set-Field $b 'cpuPriority' 'Idle'
    $memoryBefore=Read-Field $c 'memoryPriority'
    Enable-ScheduledTask -TaskName $synced.taskName|Out-Null
    Start-ScheduledTask -TaskName $synced.taskName
    Start-Sleep -Seconds 8
    $status=Core 'policy-status'
    $after=(Read-RooIndustriesOperationJson $statePath).data
    $kept=@($after.instances|Where-Object {$_.process.processId -eq $b.Id})
    $text=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
    Note 'unknownStatus' ([ordered]@{running=$status.hostRunning;records=@($after.instances).Count;recordStatus=$(if($kept.Count -gt 0){$kept[0].status});priority=(Read-Field $b 'cpuPriority');log=$text})
    Assert ($status.hostRunning -ne $true) 'The governor does not start while a saved record has an unknown status'
    Assert ((Read-Field $b 'cpuPriority') -eq 'Idle') 'The app named by the unknown record is not enforced'
    Assert ($kept.Count -eq 1 -and $kept[0].status -eq 'weird' -and @($after.instances).Count -eq $count) 'The record is left as it was and no record is added'
    Assert ($text -like '*A governor record has an unknown status*') 'The refusal is written to the governor log'
    $refusal=$null
    try {Core 'policy-run' @{durationSeconds=0}|Out-Null} catch {$refusal=$_.Exception.Message}
    Note 'putBack' $refusal
    Assert ($refusal -like '*unknown status*') 'Put settings back is refused for the same reason instead of acting on a record it cannot read'
    $operation=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    $journal=Join-Path $operation 'journal.json'
    Core 'process-preview' @{processId=$c.Id;controls=@{memoryPriority=3};outputPath=$preview}|Out-Null
    $applied=Core 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal}
    Assert ($applied.status -eq 'applied' -and (Read-Field $c 'memoryPriority') -eq 3) 'Apply once still works on another app while the state holds the unknown record'
    $restored=Core 'process-restore' @{journalPath=$journal}
    Assert ($restored.status -eq 'restored' -and (Read-Field $c 'memoryPriority') -eq $memoryBefore) 'Undo of that change still works'
    $repair=(Read-RooIndustriesOperationJson $statePath).data
    foreach($instance in @($repair.instances|Where-Object {$_.status -eq 'weird'})){$instance.status='active'}
    Write-RooIndustriesOperationJson $repair $statePath
    Start-ScheduledTask -TaskName $synced.taskName
    Assert ($null -ne (Wait-Until {(Core 'policy-status').hostRunning -eq $true} 25 500)) 'Once the record has a known status the governor starts again'
    Worker 'Pause'|Out-Null
    Note 'afterPause' ([ordered]@{a=(Read-Field $a 'cpuPriority');b=(Read-Field $b 'cpuPriority');openA=@(Get-Open $a.Id).Count;openB=@(Get-Open $b.Id).Count})
    Assert ((Read-Field $a 'cpuPriority') -eq 'Normal' -and (Read-Field $b 'cpuPriority') -eq 'Normal' -and @(Get-Open $a.Id).Count -eq 0 -and @(Get-Open $b.Id).Count -eq 0) 'Put settings back then restores every app that the records cover'
}

function Test-ScenarioRuleFileDamagedLogged {
    Save-Rule (New-Rule (Copy-Probe 'RooIndustriesGovernorDamagedValid.exe' 'valid') @{cpuPriority='AboveNormal'} 'Readable rule')|Out-Null
    $id=[Guid]::NewGuid().ToString('N')
    $damaged=Join-Path $script:policyRoot ('rules\'+$id+'.json')
    [IO.File]::WriteAllText($damaged,'{"schemaVersion":1,"ruleId":',[Text.UTF8Encoding]::new($false))
    $log=Join-Path $script:policyRoot 'logs\governor.log'
    $probe=Start-Probe (Copy-Probe 'RooIndustriesGovernorDamagedProbe.exe' 'probe')
    $operation=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    $journal=Join-Path $operation 'journal.json'
    Core 'process-preview' @{processId=$probe.Id;controls=@{memoryPriority=3};outputPath=$preview}|Out-Null
    $applied=Core 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal}
    $text=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
    Note 'damagedRuleLog' ([ordered]@{status=$applied.status;log=$text})
    Assert ($applied.status -eq 'applied' -and (Read-Field $probe 'memoryPriority') -eq 3) 'Apply once on an app no readable rule owns still works while one rule file is damaged'
    Assert ($text -like ('*Skipped a damaged saved rule*'+$id+'.json*')) 'The skipped file is named in the governor log when the ownership check reads the rules'
    Core 'process-restore' @{journalPath=$journal}|Out-Null
}

function Test-ScenarioHeartbeatBootIdMissing {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Heartbeat identity')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $old=Wait-Until {([DateTime]::UtcNow-(ConvertTo-HardeningUtc (Get-GovernorState).updatedAtUtc)).TotalSeconds -gt 17} 45 1000
    Assert ($null -ne $old) 'The governor state file has not changed for more than 15 seconds'
    $healthy=Core 'policy-status'
    Assert ($healthy.hostRunning -eq $true -and -not $healthy.error) 'Control: with an old state file the heartbeat is what shows the governor is answering'
    $real=$null
    $null=Wait-Until {$script:beat=Get-Heartbeat;$null -ne $script:beat} 10
    $real=$script:beat
    $worker=Get-WorkerProcess
    Suspend-HardeningWorker $worker
    $far=[int64]$real.tick+1000000000000
    $heartbeatPath=Join-Path $script:policyRoot 'heartbeat.json'
    foreach($variant in @('absent','null','noHost','sameBootFarFuture')){
        $planted=[ordered]@{host=$real.host;tick=$far;progressTick=$far;bootId=$real.bootId;atUtc=$real.atUtc;diagnostics=$real.diagnostics}
        if($variant -eq 'absent'){$planted.Remove('bootId')}
        if($variant -eq 'null'){$planted.bootId=$null}
        if($variant -eq 'noHost'){$planted.Remove('host')}
        Write-RooIndustriesOperationJson $planted $heartbeatPath
        $status=Core 'policy-status'
        Note ('planted '+$variant) ([ordered]@{running=$status.hostRunning;error=$status.error})
        Assert ($status.hostRunning -eq $true -and [string]$status.error -like '*heartbeat is stale*') ('A heartbeat with '+$variant+' that claims a far-future beat is not trusted, so a frozen governor is not reported as answering')
    }
    [RooIndustriesGovernorScenarioOracle]::Resume($worker.Handle)
    Assert ($null -ne (Wait-Until {$s=Core 'policy-status';$s.hostRunning -eq $true -and -not $s.error} 15 300)) 'The resumed governor writes a correct heartbeat and is reported as answering again, not stale forever'
}

function Test-ScenarioRecordPathMismatch {
    $path=Copy-Probe 'RooIndustriesGovernorRecord.exe' 'real'
    $elsewhere=Copy-Probe 'RooIndustriesGovernorRecord.exe' 'elsewhere'
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Record path')
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $statePath=Join-Path $script:policyRoot 'host.json'
    Disable-ScheduledTask -TaskName $synced.taskName|Out-Null
    $worker=Get-WorkerProcess
    $worker.Kill();$worker.WaitForExit()
    $state=(Read-RooIndustriesOperationJson $statePath).data
    $record=@($state.instances|Where-Object {$_.process.processId -eq $probe.Id -and $_.status -notin @('restored','expired')})[0]
    $journal=[string]$record.journalPath
    $record.process.executablePath=$elsewhere
    Write-RooIndustriesOperationJson $state $statePath
    Enable-ScheduledTask -TaskName $synced.taskName|Out-Null
    Start-ScheduledTask -TaskName $synced.taskName
    $seen=Wait-Until {
        $now=(Read-RooIndustriesOperationJson $statePath).data
        $script:mismatch=@($now.instances|Where-Object {$_.journalPath -eq $journal -and $_.status -eq 'conflict'})[0]
        $null -ne $script:mismatch
    } 25 30
    Note 'mismatch' $script:mismatch
    Assert ($null -ne $seen -and $script:mismatch.error -eq 'The process no longer matches its saved record.') 'A record whose saved path differs from the running process is marked as a conflict and not enforced'
    $restored=Wait-Until {
        $now=(Read-RooIndustriesOperationJson $statePath).data
        @($now.instances|Where-Object {$_.journalPath -eq $journal -and $_.status -eq 'restored'}).Count -eq 1
    } 25 200
    Assert ($null -ne $restored) 'The untrusted record is put back through its own journal and closed'
    $fresh=$null
    $null=Wait-Until {$script:open=@(Get-Open $probe.Id);$script:open.Count -eq 1 -and $script:open[0].status -eq 'active'} 25 500
    $fresh=@($script:open)[0]
    Note 'freshRecord' $fresh
    Assert ($null -ne $fresh -and $fresh.process.executablePath -eq $path -and $fresh.journalPath -ne $journal) 'The rule then gets a new record that names the real path'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'The app ends up under the rule again'
}

function Test-ScenarioPathRuleOtherFolder {
    $pathA=Copy-Probe 'RooIndustriesGovernorFolder.exe' 'a'
    $pathB=Copy-Probe 'RooIndustriesGovernorFolder.exe' 'b'
    $a=Start-Probe $pathA;$b=Start-Probe $pathB
    $rule=New-Rule $pathA @{cpuPriority='AboveNormal'} 'Folder A only' 'path'
    Use-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Field $a 'cpuPriority' 'AboveNormal')) 'The app at the rule''s path is controlled'
    Start-Sleep -Seconds 6
    $issues=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $b.Id})
    Note 'sameNameOtherFolder' ([ordered]@{priority=(Read-Field $b 'cpuPriority');records=@(Get-Records $b.Id).Count;issues=$issues})
    Assert ((Read-Field $b 'cpuPriority') -eq 'Normal' -and @(Get-Records $b.Id).Count -eq 0) 'A same-named app in another folder is not controlled by a path rule'
    Assert ($issues.Count -eq 0) 'It is not reported either, because the rule was never about it'
    $rule.matchMode='filename'
    Save-Rule $rule|Out-Null
    Assert ($null -ne (Wait-Field $b 'cpuPriority' 'AboveNormal' 20)) 'Control: the same app is controlled once the rule matches by file name, so only its folder kept it out'
}

function Test-ScenarioRuleEdgeValues {
    $probe=Start-Probe (Copy-Probe 'RooIndustriesGovernorEdgeProbe.exe' 'probe')
    $choice=Get-TopologyChoice $probe
    $make={param($Controls,$Selection,$Name) $script:edgeIndex++;New-Rule (Copy-Probe ('RooIndustriesGovernorEdge'+$script:edgeIndex+'.exe') 'edge') $Controls $Name 'path' $Selection}
    $script:edgeIndex=0
    $bad=@{kind='logical';topologyHash=$choice.topologyHash;processors=@();oneThreadPerCore=$false}
    Assert-HardeningRefused {Save-Rule (& $make @{cpuPriority='Realtime'} $null 'Realtime CPU')} 'Realtime CPU priority can freeze the PC' 'A saved rule cannot set Realtime CPU priority'
    Assert-HardeningRefused {Save-Rule (& $make @{gpuPriority=5} $null 'Realtime GPU')} 'Realtime GPU priority can freeze the PC' 'A saved rule cannot set Realtime GPU priority'
    Assert-HardeningRefused {Save-Rule (& $make @{} $bad 'No CPUs')} 'chooses no processors' 'A saved rule cannot select an empty list of CPUs'
    Assert-HardeningRefused {Save-Rule (& $make @{} @{kind='logical';topologyHash=$choice.topologyHash;processors=@($choice.selection.processors[0],$choice.selection.processors[0]);oneThreadPerCore=$false} 'Repeated CPU')} 'repeats a processor' 'A saved rule cannot repeat a CPU'
    Assert-HardeningRefused {Save-Rule (& $make @{} @{kind='bogus';topologyHash=$choice.topologyHash;processors=@();oneThreadPerCore=$false} 'Unknown selection')} 'The saved CPU selection is unknown' 'A saved rule cannot use an unknown CPU selection'
    Assert-HardeningRefused {Save-Rule (& $make @{} @{kind='all';topologyHash=$null;processors=@();oneThreadPerCore=$false} 'Unreviewed selection')} 'needs a reviewed topology fingerprint' 'A saved CPU selection needs the reviewed topology fingerprint'
    Assert-HardeningRefused {Save-Rule (& $make @{} @{kind='core';topologyHash=$choice.topologyHash;processors=@();oneThreadPerCore=$false} 'Core without index')} 'needs a group and an index' 'A saved core selection needs a group and an index'
    Assert-HardeningRefused {Save-Rule (& $make @{cpuSets=@()} $null 'Opaque empty CPU sets')} 'semantic selection' 'A saved rule cannot store opaque CPU Set IDs, not even an empty list'
    Assert-HardeningRefused {Save-Rule (& $make @{executionQoS=@{controlMask=2;stateMask=2}} $null 'Undocumented power bit')} 'documented execution speed and timer resolution bits' 'A saved rule cannot carry power mode bits that are not documented'
    Assert-HardeningRefused {Save-Rule (& $make @{executionQoS=@{controlMask=1;stateMask=8}} $null 'Undocumented state bit')} 'documented execution speed and timer resolution bits' 'A saved rule cannot carry an undocumented power mode state bit'
    Assert (@(Core 'rules-list').Count -eq 0) 'None of the refused rules was saved'
    $accepted=[ordered]@{
        'High CPU priority'=@{controls=@{cpuPriority='High'};selection=$null}
        'GPU priority 4'=@{controls=@{gpuPriority=4};selection=$null}
        'One CPU'=@{controls=@{};selection=$choice.selection}
        'Windows default CPUs'=@{controls=@{};selection=@{kind='windowsDefault';topologyHash=$null;processors=@();oneThreadPerCore=$false}}
        'Power mode eco'=@{controls=@{executionQoS=@{controlMask=1;stateMask=1}};selection=$null}
        'Power mode with timer resolution bit'=@{controls=@{executionQoS=@{controlMask=5;stateMask=5}};selection=$null}
    }
    foreach($name in $accepted.Keys){
        $rule=& $make $accepted[$name].controls $accepted[$name].selection $name
        $saved=$null;$failure=$null
        try {$saved=Save-Rule $rule} catch {$failure=$_.Exception.Message}
        Note ('accepted: '+$name) $failure
        Assert ($null -eq $failure -and $null -ne $saved) ('The neighbouring value still saves: '+$name)
    }
    Assert (@(Core 'rules-list').Count -eq $accepted.Count) 'Every neighbouring rule is listed'
    $planted=& $make @{cpuPriority='Realtime'} $null 'Planted Realtime'
    $planted.revision=[Guid]::NewGuid().ToString('N')
    Write-RooIndustriesOperationJson $planted (Join-Path $script:policyRoot ('rules\'+$planted.ruleId+'.json'))
    $summary=Core 'policy-summary'
    Note 'plantedRealtime' @($summary.unreadableRules)
    Assert (@($summary.unreadableRules|Where-Object {$_ -like ('*'+$planted.ruleId+'.json*Realtime CPU priority*')}).Count -eq 1) 'A rule file edited by hand to Realtime is refused when it is read, so the governor never applies it'
}

function Test-ScenarioWorkerRootLease {
    $path=Copy-Probe
    $probe=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Worker lease')|Out-Null
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied'
    $worker=Get-WorkerProcess
    $ruleFile=@(Get-ChildItem -LiteralPath (Join-Path $script:policyRoot 'rules') -Filter '*.json')[0].FullName
    $out=Join-Path $script:scenarioRoot 'limited-worker-root.txt'
    $moved=$script:policyParent+'-moved'
    Start-Limited (@'
$r=@()
try {[IO.Directory]::Move('@@PARENT@@','@@MOVED@@');$r+='moved'} catch {$r+='refused'}
try {[IO.File]::WriteAllText('@@PLANT@@','x');$r+='created'} catch {$r+='refused'}
try {[IO.File]::WriteAllText('@@RULE@@','x');$r+='rewritten'} catch {$r+='refused'}
try {Remove-Item -LiteralPath '@@RULE@@' -Force -ErrorAction Stop;$r+='deleted'} catch {$r+='refused'}
[IO.File]::WriteAllText('@@OUT@@',($r -join ','))
'@).Replace('@@PARENT@@',$script:policyParent).Replace('@@MOVED@@',$moved).Replace('@@PLANT@@',(Join-Path $script:policyRoot 'planted.json')).Replace('@@RULE@@',$ruleFile).Replace('@@OUT@@',$out)|Out-Null
    $null=Wait-Until {Test-Path -LiteralPath $out} 30
    $attempt=if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{'no report'}
    if(Test-Path -LiteralPath $moved){
        if(Test-Path -LiteralPath $script:policyParent){Remove-Item -LiteralPath $script:policyParent -Recurse -Force}
        [IO.Directory]::Move($moved,$script:policyParent)
    }
    Note 'workerRootLease' ([ordered]@{attempt=$attempt;workerAlive=-not $worker.HasExited})
    Assert ($attempt -eq 'refused,refused,refused,refused') 'While the governor runs, a process without elevation cannot move the rules folder, add a file to it, rewrite a rule or delete one'
    $worker.Refresh()
    Assert (-not $worker.HasExited) 'The governor keeps running'
    Set-Field $probe 'cpuPriority' 'Idle'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal' 15)) 'The rule is still enforced after those attempts'
}

function Test-ScenarioIdleWithDamagedRule {
    Core 'policy-secure'|Out-Null
    if($script:roots -notcontains $script:policyRoot){$script:roots.Add($script:policyRoot)}
    $rules=Join-Path $script:policyRoot 'rules'
    [IO.Directory]::CreateDirectory($rules)|Out-Null
    $name=[Guid]::NewGuid().ToString('N')+'.json'
    [IO.File]::WriteAllText((Join-Path $rules $name),'{"schemaVersion":1,"ruleId":',[Text.UTF8Encoding]::new($false))
    $startError=$null
    try {Worker 'Sync'|Out-Null} catch {$startError=$_.Exception.Message}
    Start-Sleep -Seconds 6
    $status=Core 'policy-status'
    $summary=Core 'policy-summary'
    Note 'idleWithDamagedRule' ([ordered]@{startError=$startError;running=$status.hostRunning;errors=@($status.state.errors);unreadable=@($summary.unreadableRules);enabledRules=$summary.enabledRules})
    Assert ($null -eq $startError) 'Start governor works when the only saved rule file is damaged'
    Assert ($status.hostRunning -eq $true) 'The governor does not exit as idle while a rule file is damaged'
    Assert (@($status.state.errors|Where-Object {$_ -like ('*'+$name+'*')}).Count -ge 1) 'The governor state names the damaged file'
    Assert (@($summary.unreadableRules|Where-Object {$_ -like ('*'+$name+'*')}).Count -eq 1 -and $summary.enabledRules -eq 0) 'The summary names the damaged file and shows no enabled rule'
    Start-Sleep -Seconds 10
    $later=Core 'policy-status'
    Assert ($later.hostRunning -eq $true -and @($later.state.errors|Where-Object {$_ -like ('*'+$name+'*')}).Count -ge 1) 'The governor is still running and still naming the file after the read grace period'
    Remove-Item -LiteralPath (Join-Path $rules $name) -Force
    Assert ($null -ne (Wait-Until {(Core 'policy-status').hostRunning -ne $true} 20 500)) 'Once the damaged file is gone and no rule is on, the governor exits as idle'
}

function Test-ScenarioPathRuleUnreadableImage {
    $system=$null
    foreach($name in @('Registry','Memory Compression')){if($null -eq $system){$system=@(Get-Process -Name $name -ErrorAction SilentlyContinue)[0]}}
    Assert ($null -ne $system) 'This PC has a system process without a program file, whose program path cannot be read'
    $rule=New-Rule (Join-Path $env:SystemRoot ('System32\'+$system.ProcessName)) @{cpuPriority='AboveNormal'} 'Unreadable program path' 'path'
    Use-Rule $rule|Out-Null
    $null=Wait-Until {$script:matching=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $system.Id});$script:matching.Count -gt 0} 20 500
    Start-Sleep -Seconds 4
    $issues=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $system.Id})
    Note 'unreadablePath' ([ordered]@{process=$system.ProcessName;id=$system.Id;issues=$issues})
    Assert ($issues.Count -eq 1 -and $issues[0].ruleId -eq $rule.ruleId -and $issues[0].kind -eq 'unavailable' -and $issues[0].message -eq 'Its program path could not be read, so this rule cannot be applied to it.') 'A path rule reports a same-named app whose program path cannot be read, once, instead of skipping it silently'
    Assert (@(Get-Records $system.Id).Count -eq 0) 'No record is created for it'
}

function Test-ScenarioOwnershipNonExeImage {
    Initialize-ClaimsRedirect
    $path=Copy-Probe 'HardeningNonExe.scr'
    $probe=Start-Probe $path
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'} 'Program that is not an exe file' 'filename') $script:claimsRules|Out-Null
    $result=Invoke-ClaimsChild @'
. (Join-Path $scriptsRoot 'GovernorOwnership.Common.ps1')
$process=Get-Process -Id ([int]$processId)
$name=''
try {$name=$process.ProcessName} catch {}
[IO.File]::WriteAllText($resultPath,(@{name=$name;controls=@(Get-RooIndustriesGovernorProcessControls $process)}|ConvertTo-Json -Compress))
'@ @{processId=$probe.Id}
    Note 'nonExeOwnership' $result
    Assert (@($result.controls) -contains 'cpuPriority') 'A file-name rule for a program that is not an .exe file is seen as owning its control by the PowerShell features'
}
