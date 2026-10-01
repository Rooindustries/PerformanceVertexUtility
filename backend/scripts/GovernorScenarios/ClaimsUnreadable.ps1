function Assert-ClaimsRefusedWith([scriptblock]$Action,[string[]]$Parts,[string]$Message){
    $text=$null
    try {& $Action|Out-Null} catch {$text=$_.Exception.Message}
    Note ('refusal: '+$Message) $text
    $missing=@($Parts|Where-Object {$null -eq $text -or $text.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -lt 0})
    Assert ($null -ne $text -and $missing.Count -eq 0) ($Message+' ['+($Parts -join ' | ')+']')
}

function Write-ClaimsRecord([string]$Path,$Value){
    $text=if($Value -is [string]){$Value}else{$Value|ConvertTo-Json -Depth 12}
    [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}

function New-ClaimsSessionFiles([string]$Repo,[string]$Kind,[string]$Id,$Session,$Backup){
    $directory=Join-Path $Repo ('backend\state\'+$Kind+'\'+$Id)
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $files=[pscustomobject]@{directory=$directory;session=(Join-Path $directory 'session.json');backup=(Join-Path $directory 'backup.json')}
    if($null -ne $Session){Write-ClaimsRecord $files.session $Session}
    if($null -ne $Backup){Write-ClaimsRecord $files.backup $Backup}
    return $files
}

function New-ClaimsSession([string]$Id,[string]$Status='running',[bool]$Restorable=$true,$Active=@()){
    return [ordered]@{sessionId=$Id;status=$Status;sessionStatus=$Status;restorable=$Restorable;activeRestraints=@($Active);restoredItems=@()}
}

function New-ClaimsSnapshot([Diagnostics.Process]$Probe,[string]$Path,[string]$Original='Normal',[bool]$WithProcessId=$true,[string]$Proposed='AboveNormal'){
    $snapshot=[ordered]@{}
    if($WithProcessId){$snapshot['processId']=$Probe.Id}
    $snapshot['processName']=[IO.Path]::GetFileName($Path)
    $snapshot['executablePath']=$Path
    if($Original){$snapshot['originalPriorityClass']=$Original}
    $snapshot['proposedPriorityClass']=$Proposed
    $snapshot['controlChanges']=@([ordered]@{control='priorityClass';currentValue='Normal';proposedValue=$Proposed})
    $snapshot['processStartTimeUtc']=$Probe.StartTime.ToUniversalTime().ToString('o')
    $snapshot['capturedAtUtc']=[DateTime]::UtcNow.ToString('o')
    return $snapshot
}

function New-ClaimsJournalPath([string]$Prefix){
    $directory=Join-Path $script:policyParent ('operations\'+$Prefix+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    return (Join-Path $directory 'journal.json')
}

function Save-ClaimsAndRemove($Rule,[string]$Repo,[string]$Message){
    Save-ClaimsRule $Rule $script:policyRoot $Repo|Out-Null
    Assert $true $Message
    Remove-ClaimsRule $Rule
}

function Test-ScenarioClaimsUnreadableSessionFile {
    $name='ClaimsUnreadable.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $otherPath=Copy-Probe 'ClaimsUnreadableOther.exe'
    $other=Start-Probe $otherPath
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $session=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Start-GameTuneSession.ps1') -ProfilePath (New-ClaimsProfile $name 'game') -StateRoot $state -MaxDurationSeconds 1 -PollIntervalSeconds 1 -ConfirmApply)
    Assert ($session.restorable -eq $true -and (Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'Game priority raised the probe and left a restorable session'
    $sessionFile=@(Get-ChildItem -LiteralPath (Join-Path $state 'game-tune-sessions') -Filter 'session.json' -Recurse -File)[0].FullName
    Save-ClaimsRule (New-Rule $otherPath @{memoryPriority=3}) $script:policyRoot $repo|Out-Null
    $held=Hold-File $sessionFile 0
    $script:cleanups.Add({$held.stream.Dispose()}.GetNewClosure())
    $clock=[Diagnostics.Stopwatch]::StartNew()
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @($sessionFile,'delete it','Game priority','CPU priority') 'A CPU priority rule is refused while the Game priority session file stays locked'
    Assert ($clock.ElapsedMilliseconds -ge 1000) 'The refusal came only after the one second read retry window'
    Save-ClaimsAndRemove (New-Rule $path @{memoryPriority=3}) $repo 'A memory priority rule for the same app still saves while the file is locked'
    $off=New-Rule $path @{cpuPriority='High'}
    $off.enabled=$false
    Save-ClaimsAndRemove $off $repo 'A disabled CPU priority rule still saves while the file is locked'
    Worker 'Sync'|Out-Null
    Assert ($null -ne (Wait-Until {(Core 'policy-status').hostRunning -eq $true} 20 250)) 'The governor starts while the file is locked'
    Assert ($null -ne (Wait-Until {(Read-Field $other 'memoryPriority') -eq 3} 20)) 'The governor enforces the saved rule while the file is locked'
    $held.stream.Dispose()
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @('Undo the Game priority change on ClaimsUnreadable.exe') 'Once the file can be read again the real Game priority claim refuses the same save'
    $stopped=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Stop-GameTuneSession.ps1') -SessionPath $session.sessionPath -BackupPath $session.backupManifestPath -StateRoot $state -ConfirmApply)
    Assert ($stopped.restorable -eq $false -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'Game priority undo restored the probe'
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'After the file is released and the session undone the same save succeeds'
}

function Test-ScenarioClaimsDamagedBackupFile {
    $name='ClaimsDamagedBackup.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $otherPath=Copy-Probe 'ClaimsDamagedBackupOther.exe' 'other'
    $repo=New-ClaimsRepo
    $rule=New-Rule $path @{cpuPriority='High'}
    Save-ClaimsRule $rule $script:policyRoot $repo|Out-Null
    Core 'policy-pause' @{paused=$true;repoRoot=$repo}|Out-Null
    Assert ((Core 'policy-summary').paused -eq $true) 'A governor with a CPU priority rule is paused'
    $files=New-ClaimsSessionFiles $repo 'game-tune-sessions' 'game-tune-claims-damaged' (New-ClaimsSession 'game-tune-claims-damaged') '{"schemaVersion":1,"snapshots":['
    $parts=@($files.backup,'delete it','Game priority','CPU priority')
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $otherPath @{cpuPriority='High'}) $script:policyRoot $repo} $parts 'A damaged backup.json of a live-looking session refuses a CPU priority rule, even for an app the file may not concern'
    Assert-ClaimsRefusedWith {Core 'policy-pause' @{paused=$false;repoRoot=$repo}} $parts 'Resuming the governor is refused while the damaged backup.json could hide a held CPU priority'
    Assert ((Core 'policy-summary').paused -eq $true) 'The refused resume left the governor paused'
    Save-ClaimsAndRemove (New-Rule $path @{memoryPriority=3}) $repo 'A memory priority rule is not affected by the damaged file'
    Remove-Item -LiteralPath $files.backup
    Core 'policy-pause' @{paused=$false;repoRoot=$repo}|Out-Null
    Assert ((Core 'policy-summary').paused -eq $false) 'After the damaged file is deleted the governor resumes'
    Save-ClaimsRule $rule $script:policyRoot $repo|Out-Null
    Assert $true 'After the damaged file is deleted the CPU priority rule saves'
}

function Test-ScenarioClaimsNoRecordedOriginal {
    $name='ClaimsNoOriginal.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    Set-Field $probe 'cpuPriority' 'AboveNormal'
    $text='Undo the Game priority change on ClaimsNoOriginal.exe (or close ClaimsNoOriginal.exe) first'
    $files=New-ClaimsSessionFiles $repo 'game-tune-sessions' 'game-tune-claims-no-original' (New-ClaimsSession 'game-tune-claims-no-original' 'completed') ([ordered]@{sessionId='game-tune-claims-no-original';snapshots=@(New-ClaimsSnapshot $probe $path '')})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @($text,'CPU priority') 'A live Game priority snapshot with no recorded original counts as held'
    Write-ClaimsRecord $files.backup ([ordered]@{sessionId='game-tune-claims-no-original';snapshots=@(New-ClaimsSnapshot $probe $path 'NotAPriority')})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @($text,'CPU priority') 'A live Game priority snapshot whose original is not restorable counts as held'
    Save-ClaimsAndRemove (New-Rule $path @{ioPriority=1}) $repo 'A field the snapshot did not change is not blocked'
    Remove-Item -LiteralPath $files.directory -Recurse -Force
    $pointer=Join-Path $script:policyParent 'settings\process-profile-recovery.json'
    [IO.Directory]::CreateDirectory((Split-Path $pointer -Parent))|Out-Null
    $profileBackup=Join-Path $script:scenarioRoot 'profile-backup.json'
    Write-ClaimsRecord $profileBackup ([ordered]@{actionId='performance.applyProfile';backupId='claims-no-original';profileId='claims-background';dryRun=$false;snapshots=@(New-ClaimsSnapshot $probe $path '')})
    Write-ClaimsRecord $pointer ([ordered]@{path=$profileBackup;id='claims-no-original';generation=[Guid]::NewGuid().ToString('N')})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @('Undo the Background priorities change on ClaimsNoOriginal.exe','CPU priority') 'A live Background priorities snapshot with no recorded original counts as held'
    Remove-Item -LiteralPath $pointer
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    $limit=New-ClaimsSnapshot $probe $path '' $true 'BelowNormal'
    $limits=New-ClaimsSessionFiles $repo 'process-governor-sessions' 'process-governor-claims-no-original' (New-ClaimsSession 'process-governor-claims-no-original' 'completed' $true @([ordered]@{processId=$probe.Id;processName=$name;executablePath=$path;snapshot=$limit})) ([ordered]@{sessionId='process-governor-claims-no-original';snapshots=@($limit)})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @('Undo the Background limits change on ClaimsNoOriginal.exe','CPU priority') 'A restrained app is held by Background limits although the record has no original, because only the restraint value is compared'
    Set-Field $probe 'cpuPriority' 'High'
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'A value changed by someone else, which Background limits would preserve, does not block'
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @('Undo the Background limits change on ClaimsNoOriginal.exe') 'The restrained app is held again once it carries the restraint value'
    $probe.Kill();$probe.WaitForExit(10000)|Out-Null
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'A record for an exited process is ignored even when it has no original'
}

function Test-ScenarioClaimsSnapshotWithoutProcess {
    $name='ClaimsNoProcess.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $files=New-ClaimsSessionFiles $repo 'game-tune-sessions' 'game-tune-claims-no-process' (New-ClaimsSession 'game-tune-claims-no-process' 'completed') ([ordered]@{sessionId='game-tune-claims-no-process';snapshots=@(New-ClaimsSnapshot $probe $path 'Normal' $false)})
    $parts=@($files.backup,'delete it','Game priority','CPU priority')
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} $parts 'A Game priority snapshot that does not say which process it changed blocks the field it holds and names the file'
    Save-ClaimsAndRemove (New-Rule $path @{ioPriority=1}) $repo 'A field that snapshot did not change is not blocked'
    Save-ClaimsAndRemove (New-Rule (Copy-Probe 'ClaimsNoProcessOther.exe' 'other') @{memoryPriority=3}) $repo 'An unrelated rule is not blocked'
    $blocked=New-ClaimsSnapshot $probe $path 'Normal' $false
    $blocked.controlChanges=@([ordered]@{control='priorityClass';currentValue='Normal';proposedValue='AboveNormal';blocked=$true})
    Write-ClaimsRecord $files.backup ([ordered]@{sessionId='game-tune-claims-no-process';snapshots=@($blocked)})
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'A snapshot whose only change was blocked holds nothing'
    Remove-Item -LiteralPath $files.directory -Recurse -Force
    $limit=New-ClaimsSnapshot $probe $path 'Normal' $false 'BelowNormal'
    $limits=New-ClaimsSessionFiles $repo 'process-governor-sessions' 'process-governor-claims-no-process' (New-ClaimsSession 'process-governor-claims-no-process' 'completed' $true @([ordered]@{processName=$name;executablePath=$path;snapshot=$limit})) ([ordered]@{sessionId='process-governor-claims-no-process';snapshots=@()})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @($limits.session,'delete it','Background limits','CPU priority') 'A Background limits restraint without a process ID blocks the field and names session.json'
    Remove-Item -LiteralPath $limits.directory -Recurse -Force
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'After the records are deleted the CPU priority rule saves'
}

function Test-ScenarioClaimsDamagedJournals {
    $name='ClaimsDamagedJournal.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $choice=Get-TopologyChoice $probe
    $apply=New-ClaimsJournalPath 'process-'
    Write-ClaimsRecord $apply '{"schemaVersion":1,"status":"applied","changes":['
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{memoryPriority=3}) $script:policyRoot $repo} @($apply,'delete it','Apply once','Memory priority') 'A damaged Apply once journal could hold any setting, so even a memory priority rule is refused'
    Remove-Item -LiteralPath (Split-Path $apply -Parent) -Recurse -Force
    Save-ClaimsAndRemove (New-Rule $path @{memoryPriority=3}) $repo 'After the damaged Apply once journal is deleted the rule saves'
    $cpu=New-ClaimsJournalPath 'cpu-'
    Write-ClaimsRecord $cpu '{"schemaVersion":1,"kind":"cpu-set-journal","status":'
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{} -CpuSelection $choice.selection) $script:policyRoot $repo} @($cpu,'delete it','CPU selection','Preferred CPUs') 'A damaged CPU selection journal refuses a Preferred CPUs rule'
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'A damaged CPU selection journal can only hold Preferred CPUs, so a CPU priority rule saves'
    Remove-Item -LiteralPath (Split-Path $cpu -Parent) -Recurse -Force
    Save-ClaimsAndRemove (New-Rule $path @{} -CpuSelection $choice.selection) $repo 'After the damaged CPU selection journal is deleted the Preferred CPUs rule saves'
    $pointer=Join-Path $script:policyParent 'settings\process-profile-recovery.json'
    [IO.Directory]::CreateDirectory((Split-Path $pointer -Parent))|Out-Null
    Write-ClaimsRecord $pointer '{"path":'
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @($pointer,'delete it','Background priorities','CPU priority') 'A damaged Background priorities recovery pointer refuses a CPU priority rule'
    Save-ClaimsAndRemove (New-Rule $path @{memoryPriority=3}) $repo 'A damaged recovery pointer cannot hold memory priority, so that rule saves'
    Remove-Item -LiteralPath $pointer
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'After the damaged recovery pointer is deleted the CPU priority rule saves'
}

function Test-ScenarioClaimsJournalWithoutProcess {
    $name='ClaimsJournalNoProcess.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $choice=Get-TopologyChoice $probe
    $apply=New-ClaimsJournalPath 'process-'
    $journal=[ordered]@{schemaVersion=1;status='applied';changes=@([ordered]@{name='cpuPriority';status='applied'});preview=[ordered]@{identity=[ordered]@{executablePath=$path}}}
    Write-ClaimsRecord $apply $journal
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} @($apply,'delete it','Apply once','CPU priority') 'An Apply once journal that does not say which process it changed blocks the field it holds and names the file'
    Save-ClaimsAndRemove (New-Rule $path @{memoryPriority=3}) $repo 'A field that journal did not change is not blocked'
    $journal.status='restored'
    Write-ClaimsRecord $apply $journal
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'Once the journal says restored the same rule saves'
    $cpu=New-ClaimsJournalPath 'cpu-'
    Write-ClaimsRecord $cpu ([ordered]@{schemaVersion=1;kind='cpu-set-journal';status='applied';preview=[ordered]@{identity=[ordered]@{executablePath=$path}}})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $path @{} -CpuSelection $choice.selection) $script:policyRoot $repo} @($cpu,'delete it','CPU selection','Preferred CPUs') 'A CPU selection journal without a process ID blocks Preferred CPUs and names the file'
    Save-ClaimsAndRemove (New-Rule $path @{cpuPriority='High'}) $repo 'A CPU priority rule is not blocked by that CPU selection journal'
    Remove-Item -LiteralPath (Split-Path $cpu -Parent) -Recurse -Force
    Save-ClaimsAndRemove (New-Rule $path @{} -CpuSelection $choice.selection) $repo 'After the journal is deleted the Preferred CPUs rule saves'
}

function Test-ScenarioClaimsGameBackupFirst {
    $name='ClaimsGameFirst.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $sessions=Join-Path $state 'game-tune-sessions'
    $env:ROO_INDUSTRIES_TEST_GAMETUNE_PAUSE_MS='60000'
    try {$child=Start-ClaimsChild '$output=@(& (Join-Path $scriptsRoot ''Start-GameTuneSession.ps1'') -ProfilePath $profilePath -StateRoot $stateRoot -MaxDurationSeconds 1 -PollIntervalSeconds 1 -ConfirmApply) -join "`n";[IO.File]::WriteAllText($resultPath,$output)' @{profilePath=(New-ClaimsProfile $name 'game');stateRoot=$state}}
    finally {Remove-Item -LiteralPath 'Env:\ROO_INDUSTRIES_TEST_GAMETUNE_PAUSE_MS'}
    $recorded={$file=@(Get-ChildItem -LiteralPath $sessions -Filter 'session.json' -Recurse -File)[0];$json=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json;if($json.restorable -eq $true -and $json.backupManifestPath){$json}}
    $ready=Wait-Until {$null -ne (& $recorded)} 90 100
    Note 'secondsToRecordedSession' $ready
    $cpuAtRecord=Read-Field $probe 'cpuPriority'
    try {& (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $child.process.Id /T /F 2>&1|Out-Null} catch {}
    $null=$child.process.WaitForExit(15000)
    $sessionFile=@(Get-ChildItem -LiteralPath $sessions -Filter 'session.json' -Recurse -File)[0].FullName
    Assert ($null -ne $ready -and $child.process.HasExited) 'The session recorded itself as restorable and the PowerShell tree was then killed during the apply pause'
    Assert ($cpuAtRecord -eq 'Normal' -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'No change had landed on the probe when the session first recorded itself, nor when it was killed'
    $session=[IO.File]::ReadAllText($sessionFile)|ConvertFrom-Json
    $backup=[IO.File]::ReadAllText($session.backupManifestPath)|ConvertFrom-Json
    $snapshot=@($backup.snapshots)[0]
    Note 'backupAfterKill' $backup
    Assert ($backup.actionId -eq 'performance.gameTune.startSession' -and $backup.dryRun -eq $false -and @($backup.snapshots).Count -eq 1 -and $snapshot.processId -eq $probe.Id -and $snapshot.originalPriorityClass -eq 'Normal' -and $snapshot.proposedPriorityClass -eq 'AboveNormal') 'backup.json holds the original CPU priority of the probe although the apply never ran'
    Assert ($session.restorable -eq $true -and $session.sessionStatus -eq 'running' -and [IO.Path]::GetFileName($session.backupManifestPath) -eq 'backup.json') 'session.json says the session is running and restorable and points at that backup'
    $stopped=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Stop-GameTuneSession.ps1') -SessionPath $session.sessionPath -BackupPath $session.backupManifestPath -StateRoot $state -ConfirmApply)
    Note 'undoAfterKill' @{status=$stopped.status;restorable=$stopped.restorable;errors=@($stopped.errors|ForEach-Object {$_.message})}
    Assert ($stopped.status -eq 'completed' -and $stopped.restorable -eq $false -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'Undo finds the killed session through its backup and ends restored'
}

function Test-ScenarioClaimsOtherAccountSession {
    $name='ClaimsOtherAccount.exe'
    $systemPath=Copy-Probe $name 'system'
    $userPath=Copy-Probe $name 'user'
    $system=Start-SystemProcess $systemPath '900'
    $own=Start-Probe $userPath
    $repo=New-ClaimsRepo
    $id='game-tune-claims-other-account'
    $foreign=New-ClaimsSnapshot $system $systemPath 'BelowNormal'
    $mine=New-ClaimsSnapshot $own $userPath 'BelowNormal'
    $files=New-ClaimsSessionFiles $repo 'game-tune-sessions' $id (New-ClaimsSession $id 'completed') ([ordered]@{sessionId=$id;snapshots=@($foreign)})
    Save-ClaimsAndRemove (New-Rule $userPath @{cpuPriority='High'} 'Other account session' 'filename') $repo 'A session snapshot whose live process runs under the SYSTEM account does not block this account''s CPU priority rule'
    $text='Undo the Game priority change on ClaimsOtherAccount.exe (or close ClaimsOtherAccount.exe) first'
    Write-ClaimsRecord $files.backup ([ordered]@{sessionId=$id;snapshots=@($mine)})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $userPath @{cpuPriority='High'} 'Own session' 'filename') $script:policyRoot $repo} @($text,'CPU priority') 'The same snapshot for a process of the current account still blocks the rule'
    Write-ClaimsRecord $files.backup ([ordered]@{sessionId=$id;snapshots=@($foreign,$mine)})
    Assert-ClaimsRefusedWith {Save-ClaimsRule (New-Rule $userPath @{cpuPriority='High'} 'Both sessions' 'filename') $script:policyRoot $repo} @($text,'CPU priority') 'A record that lists both still blocks because of the current account''s process'
    Remove-Item -LiteralPath $files.directory -Recurse -Force
    Save-ClaimsAndRemove (New-Rule $userPath @{cpuPriority='High'} 'After the records are gone' 'filename') $repo 'After the record is deleted the rule saves'
}

function Test-ScenarioGuardUnreadableHostState {
    $setup=Start-ClaimsHostState
    $ownerName=Split-Path $setup.path -Leaf
    $name='ClaimsGuardFree.exe'
    $freePath=Copy-Probe $name
    $free=Start-Probe $freePath
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $before=Read-Field $setup.probe 'cpuPriority'
    $held=Hold-File $setup.hostState 0
    $script:cleanups.Add({$held.stream.Dispose()}.GetNewClosure())
    $body=@'
. (Join-Path $scriptsRoot 'GovernorOwnership.Common.ps1')
$clock=[Diagnostics.Stopwatch]::StartNew()
$matched=@(Get-RooIndustriesGovernorOwnedControls -ProcessId ([int]$ownerId) -ExecutablePath $ownerPath -CreationTimeFileTimeUtc $ownerCreated)
$matchedMs=$clock.ElapsedMilliseconds
$unmatched=@(Get-RooIndustriesGovernorOwnedControls -ProcessId ([int]$freeId) -ExecutablePath $freePath -CreationTimeFileTimeUtc $freeCreated)
[IO.File]::WriteAllText($resultPath,(@{matched=$matched;matchedMs=$matchedMs;unmatched=$unmatched}|ConvertTo-Json -Compress))
'@
    $calls=Invoke-ClaimsChild $body @{ownerId=$setup.probe.Id;ownerPath=$setup.path;ownerCreated=[string]$setup.probe.StartTime.ToUniversalTime().ToFileTimeUtc();freeId=$free.Id;freePath=$freePath;freeCreated=[string]$free.StartTime.ToUniversalTime().ToFileTimeUtc()}
    Note 'ownershipWhileLocked' $calls
    Assert (@($calls.matched).Count -eq 8 -and $calls.matchedMs -ge 700 -and $calls.matchedMs -lt 2000) 'With host.json locked, an app an enabled rule matches is read as fully managed after a retry of under two seconds'
    Assert (@($calls.unmatched).Count -eq 0) 'With host.json locked, an app no rule matches is not read as managed'
    $unrelated=Invoke-ClaimsFeature 'Start-GameTuneSession.ps1' @{ProfilePath=(New-ClaimsProfile $name 'game');StateRoot=$state;MaxDurationSeconds=1;PollIntervalSeconds=1;ConfirmApply=$true}
    Note 'unrelatedGame' @{restorable=$unrelated.restorable;skipped=@($unrelated.skippedItems|ForEach-Object {$_.reason})}
    Assert ($unrelated.restorable -eq $true -and (Read-Field $free 'cpuPriority') -eq 'AboveNormal') 'Game priority changes an app no rule matches while host.json stays locked'
    $matched=Invoke-ClaimsFeature 'Start-GameTuneSession.ps1' @{ProfilePath=(New-ClaimsProfile $ownerName 'game');StateRoot=$state;MaxDurationSeconds=1;PollIntervalSeconds=1;ConfirmApply=$true}
    Note 'matchedGame' @{skipped=@($matched.skippedItems|ForEach-Object {$_.reason})}
    Assert ((Read-Field $setup.probe 'cpuPriority') -eq $before -and @($matched.skippedItems|Where-Object {$_.reason -like '*Managed by the governor*'}).Count -gt 0) 'Game priority still leaves an app an enabled rule matches alone and reports Managed by the governor'
    $log=Join-Path $script:claimsData 'process-rules\logs\governor.log'
    $text=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
    Note 'governorLog' $text
    Assert ($text -like '*Could not read the saved rules*host.json*') 'The unreadable host.json is logged'
}

function Test-ScenarioClaimsGatePolicySession {
    $name='ClaimsGatePolicy.exe'
    $path=Copy-Probe $name
    $marker='claims-gate-policy-marker'
    $probe=Start-Probe $path ('3600 '+$marker)
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $profilePath=Join-Path $script:scenarioRoot 'policy-gate.profile.json'
    $rule=[ordered]@{ruleId='claims-gate-policy';enabled=$true;allowConfirmedApply=$true;match=[ordered]@{processNames=@($name);commandLinePatterns=@('*'+$marker+'*')};controls=[ordered]@{priorityClass='BelowNormal'};reason='Claims gate scenario.';reasonCodes=@('CLAIMS_GATE_POLICY');scenarioTags=@('validation');risk='low'}
    $profile=[ordered]@{schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='claims-gate-policy';name='Claims gate policy';profileKind='persistent-process-policy';risk='low';targetScenario='Claims gate scenario.'
        protectedCatalogPath=(Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        policy=[ordered]@{session=[ordered]@{pollIntervalSeconds=1;maxSessionDurationSeconds=2};safety=[ordered]@{confirmedApplyRequiresRuleAllow=$true;confirmedApplyRequiresPathRoot=$true;confirmedApplyPathRoots=@((Split-Path $path -Parent))};protectedProcesses=@();rules=@($rule)}
        telemetryTargets=@('persistent-policy-enforcement')
        rollbackPolicy=[ordered]@{supported=$true;scope='persistent-process-policy-controls';stateRoot='temp-validation-state';restoreOriginalPriorityClass=$true;restoreOriginalAffinityMask=$true;restoreOriginalIoPriority=$true;restoreOriginalGpuPriority=$true}
        safety=[ordered]@{confirmedApplyChanges=@('priorityClass');continuousEnforcement=$true;runtimeService=$false;requiresExplicitApplyRoots=$true}}
    Write-ClaimsRecord $profilePath $profile
    $holder=Start-ClaimsGateHolder 12000
    $session=Start-ClaimsChild '$output=@(& (Join-Path $scriptsRoot ''Start-ProcessPolicySession.ps1'') -ProfilePath $profilePath -StateRoot $stateRoot -MaxDurationSeconds 2 -PollIntervalSeconds 1 -ConfirmApply -IncludeCommandLine) -join "`n";[IO.File]::WriteAllText($resultPath,$output)' @{profilePath=$profilePath;stateRoot=$state}
    $during=Watch-ClaimsDuringHold $holder $probe 'cpuPriority'
    $result=Wait-ClaimsChild $session
    Note 'policySessionGate' @{during=$during;status=$result.status;restorable=$result.restorable;changed=@($result.changedItems).Count;warnings=@($result.warnings|ForEach-Object {$_.code});error=$result.error}
    Assert ((@($during) -join ',') -eq 'Normal') 'A persistent policy session did not change the probe while a rule change held the governor gate'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'BelowNormal' -and $result.restorable -eq $true) 'The persistent policy session changed the probe after the gate was released and left a restorable session'
    $stopped=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Stop-ProcessPolicySession.ps1') -SessionPath $result.sessionPath -ConfirmApply)
    Assert ($stopped.restorable -eq $false -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'Stopping the persistent policy session put the probe back'
    Wait-ClaimsChild $holder.child|Out-Null
}
