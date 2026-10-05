function Test-ScenarioReassertRemove {Test-ScenarioReassert -RestoreAction 'Remove'}
function Test-ScenarioReassertLaterDesired {Test-ScenarioReassert -FinalPriority 'AboveNormal'}
function Test-ScenarioReassertCrash {Test-ScenarioReassert -Crash}

function Test-ScenarioRestoreForeignOwned {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $sync=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal';ioPriority=1} 'Foreign during re-assert window')
    Assert ($null -ne (Wait-Until {$c=Read-Controls $probe;$c.cpuPriority -eq 'AboveNormal' -and $c.ioPriority -eq 1} 10)) 'Both fields are enforced before the interrupted restore'
    Disable-ScheduledTask -TaskName $sync.taskName|Out-Null
    $worker=Get-WorkerProcess;$worker.Kill();$worker.WaitForExit()
    Set-Field $probe 'cpuPriority' 'Idle'
    $records=@(Get-Open $probe.Id)
    Assert (@($records|Where-Object {$_.field -eq 'cpuPriority' -and $_.status -eq 'active' -and $null -eq $_.errorKind}).Count -eq 1) 'The foreign field is still recorded as owned inside the re-assert window'
    Worker 'Pause'|Out-Null
    $after=Read-Controls $probe
    Note 'foreignOwnedAfterRecovery' $after
    Assert ($after.cpuPriority -eq 'Idle' -and $after.ioPriority -eq 2) 'Restore-Interrupted leaves a foreign value and restores the unchanged owned value'
    foreach($record in @(Get-Records $probe.Id)){
        $journal=(Read-RooIndustriesOperationJson $record.journalPath).data
        Note ('recovered-'+$record.field) @{record=$record;journal=$journal}
        if($record.field -eq 'cpuPriority'){
            Assert ($record.status -eq 'restored' -and $record.errorKind -eq 'leftAsSet' -and $journal.status -eq 'restored' -and $journal.changes[0].status -eq 'leftAsSet' -and $journal.changes[0].observed -eq 'Idle') 'Foreign changed owned fields close as leftAsSet with their successful read'
        } else {
            Assert ($record.status -eq 'restored' -and $null -eq $record.errorKind -and $journal.status -eq 'restored' -and $journal.changes[0].status -eq 'restored' -and $journal.changes[0].observed -eq 2) 'Unchanged owned fields close with confirmed original readback'
        }
    }
}
function Test-ScenarioReassertRetryDenied { Test-ScenarioReassert -RetryDenied }

function Test-ScenarioCrashAfterLeftAsSetJournal {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $sync=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal';ioPriority=1} 'Terminal foreign journal recovery')
    Assert ($null -ne (Wait-Until {$c=Read-Controls $probe;$c.cpuPriority -eq 'AboveNormal' -and $c.ioPriority -eq 1} 10)) 'The native rule owns both fields before the terminal journal interruption'
    Disable-ScheduledTask -TaskName $sync.taskName|Out-Null
    $worker=Get-WorkerProcess;$worker.Kill();$worker.WaitForExit()
    Set-Field $probe 'cpuPriority' 'Idle'
    Worker 'Pause'|Out-Null
    $record=@(Get-Records $probe.Id|Where-Object {$_.field -eq 'cpuPriority' -and $_.errorKind -eq 'leftAsSet'})[0]
    Assert ($null -ne $record -and (Read-RooIndustriesOperationJson $record.journalPath).data.status -eq 'restored') 'The actual governor closes the foreign journal as leftAsSet before the interrupted state write'
    $statePath=Join-Path $script:policyRoot 'host.json'
    $state=(Read-RooIndustriesOperationJson $statePath).data
    foreach($instance in @($state.instances|Where-Object {$_.journalPath -eq $record.journalPath})){$instance.status='active';$instance.error=$null;$instance.errorKind=$null}
    Write-RooIndustriesOperationJson $state $statePath
    Worker 'Resume'|Out-Null
    $completed=Wait-Until {@(Get-Records $probe.Id|Where-Object {$_.journalPath -eq $record.journalPath -and $_.status -eq 'restored'}).Count -eq 1} 10
    $closed=@(Get-Records $probe.Id|Where-Object {$_.journalPath -eq $record.journalPath -and $_.status -eq 'restored'})[0]
    Note 'terminalJournalRecoveredState' $closed
    Assert ($null -ne $completed -and $null -ne $closed -and $closed.errorKind -eq 'leftAsSet' -and $closed.error -ceq 'Left as another program set it.') 'Restart preserves the terminal foreign journal outcome when the state write was interrupted'
}
