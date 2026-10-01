function Assert-Refused([scriptblock]$Action,[string]$Expected,[string]$Message){
    $text=$null
    try {& $Action|Out-Null} catch {$text=$_.Exception.Message}
    Note ('refusal: '+$Message) $text
    Assert ($null -ne $text -and $text -like ('*'+$Expected+'*')) $Message
}

function Save-ClaimsRule($Rule,[string]$Folder=$script:policyRoot,[string]$Repo=$repoRoot){
    if($script:roots -notcontains $Folder){$script:roots.Add($Folder)}
    return Core 'rule-save' @{rule=$Rule;repoRoot=$Repo} $Folder
}

function Remove-ClaimsRule($Rule,[string]$Folder=$script:policyRoot){Core 'rule-delete' @{ruleId=$Rule.ruleId} $Folder|Out-Null}

function Invoke-ClaimsApplyOnce([Diagnostics.Process]$Process,[hashtable]$Controls,[string]$Folder=$script:policyRoot){
    $directory=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $preview=Join-Path $directory 'preview.json'
    $journal=Join-Path $directory 'journal.json'
    Core 'process-preview' @{processId=$Process.Id;controls=$Controls;outputPath=$preview} $Folder|Out-Null
    $applied=Core 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal} $Folder
    return [pscustomobject]@{journal=$journal;status=$applied.status}
}

function Restore-ClaimsApplyOnce([string]$Journal,[string]$Folder=$script:policyRoot){return (Core 'process-restore' @{journalPath=$Journal} $Folder).status}

function New-ClaimsRepo {
    $root=Join-Path $script:scenarioRoot 'repo'
    $profiles=Join-Path $root 'backend\profiles'
    [IO.Directory]::CreateDirectory($profiles)|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root 'backend\state'))|Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'backend\profiles\protected-processes.json') -Destination $profiles
    return $root
}

function New-ClaimsProfile([string]$ImageName,[string]$Kind,[string]$IoPriority=''){
    $profile=[ordered]@{schemaVersion=1;productName='Roo Industries Optimization Suite';profileId=('claims-'+$Kind);name='Claims scenario';profileKind='process-controls';risk='low'
        protectedCatalogPath=(Join-Path $repoRoot 'backend\profiles\protected-processes.json');protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();targetGames=@();rules=@()}
    if($Kind -eq 'game'){
        $profile.foregroundGame=[ordered]@{ruleId='claims-game';processNames=@($ImageName);priorityClass='AboveNormal';reason='Claims scenario game boost.'}
        if($IoPriority){$profile.foregroundGame.ioPriority=$IoPriority}
    } else {
        $profile.rules=@([ordered]@{ruleId='claims-demote';enabled=$true;match=[ordered]@{processNames=@($ImageName)};action=[ordered]@{actionType='setPriority';priorityClass='BelowNormal';reason='Claims scenario demotion.'};risk='low';rollback=[ordered]@{restorePriorityClass=$true}})
    }
    $path=Join-Path $script:scenarioRoot ('profile-'+$Kind+'.json')
    [IO.File]::WriteAllText($path,($profile|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    return $path
}

function Read-ClaimsOutput($Lines){return (@($Lines) -join "`n")|ConvertFrom-Json}

function Remove-ClaimsProfile([string]$Folder){
    $leaf=(Split-Path $Folder -Leaf).ToUpperInvariant()
    $markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    if($markers){foreach($name in @($markers.GetValueNames()|Where-Object {$_ -like ('*\'+$leaf+'\*')})){Remove-ItemProperty -LiteralPath $markers.PSPath -Name $name}}
    for($attempt=0;$attempt -lt 20 -and (Test-Path -LiteralPath $Folder);$attempt++){
        try {Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop} catch {Start-Sleep -Milliseconds 500}
    }
    if(Test-Path -LiteralPath $Folder){throw ('The redirected profile could not be removed: '+$Folder)}
}

function Initialize-ClaimsRedirect {
    $script:claimsProfile=Join-Path ([IO.Path]::GetTempPath()) ('rc-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
    $script:cleanups.Add({
        $status=Core 'policy-status' @{} $script:claimsRules
        if($status.hostRunning -ne $false){throw ('A governor is still running for '+$script:claimsRules)}
        Remove-ClaimsProfile $script:claimsProfile
    })
    $script:claimsData=Join-Path $script:claimsProfile 'AppData\Local\RooIndustriesOptimizationSuite'
    $script:claimsRules=Join-Path $script:claimsData 'process-rules'
    [IO.Directory]::CreateDirectory($script:claimsData)|Out-Null
}

function Start-ClaimsChild([string]$Body,[hashtable]$Values=@{}){
    $id=[Guid]::NewGuid().ToString('N').Substring(0,8)
    $Values['scriptsRoot']=$scriptsRoot
    $Values['resultPath']=Join-Path $script:scenarioRoot ('child-'+$id+'.json')
    $text="`$ErrorActionPreference='Stop'`r`n`$ProgressPreference='SilentlyContinue'`r`n"
    foreach($key in $Values.Keys){$text+='$'+$key+"='"+([string]$Values[$key]).Replace("'","''")+"'`r`n"}
    $text+="function Wait-Signal([string]`$Path,[double]`$Seconds){`$clock=[Diagnostics.Stopwatch]::StartNew();while(-not (Test-Path -LiteralPath `$Path)){if(`$clock.Elapsed.TotalSeconds -gt `$Seconds){throw ('No signal '+`$Path)};Start-Sleep -Milliseconds 10}}`r`n"
    $text+="try {`r`n"+$Body+"`r`n} catch { [IO.File]::WriteAllText(`$resultPath,(@{error=`$_.Exception.Message+' '+`$_.ScriptStackTrace}|ConvertTo-Json -Compress)) }`r`n"
    $file=Join-Path $script:scenarioRoot ('child-'+$id+'.ps1')
    [IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($true))
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$file+'"'))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    if($script:claimsProfile -and (Test-Path -LiteralPath $script:claimsProfile)){$info.EnvironmentVariables['USERPROFILE']=$script:claimsProfile}
    $process=[Diagnostics.Process]::Start($info)
    $script:probes.Add($process)
    return [pscustomobject]@{process=$process;resultPath=$Values['resultPath']}
}

function Wait-ClaimsChild($Child,[int]$Seconds=240){
    if(-not $Child.process.WaitForExit($Seconds*1000)){throw 'The child PowerShell did not finish in time.'}
    if(-not (Test-Path -LiteralPath $Child.resultPath)){throw ('The child PowerShell wrote no result (exit '+$Child.process.ExitCode+').')}
    $result=[IO.File]::ReadAllText($Child.resultPath)|ConvertFrom-Json
    if($result.error -is [string]){throw ('Child failed: '+$result.error)}
    return $result
}

function Invoke-ClaimsChild([string]$Body,[hashtable]$Values=@{}){return Wait-ClaimsChild (Start-ClaimsChild $Body $Values)}

function Invoke-ClaimsFeature([string]$Script,[hashtable]$Arguments){
    $body='$splat=@{};foreach($property in (ConvertFrom-Json $argumentsJson).PSObject.Properties){$splat[$property.Name]=if($property.Value -is [bool]){[switch]$property.Value}else{$property.Value}};$output=@(& (Join-Path $scriptsRoot $scriptName) @splat) -join "`n";[IO.File]::WriteAllText($resultPath,$output)'
    return Invoke-ClaimsChild $body @{scriptName=$Script;argumentsJson=($Arguments|ConvertTo-Json -Compress)}
}

function Get-ClaimsCpuSetId([Diagnostics.Process]$Process){
    $status=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1') -Action Status -TargetProcessId $Process.Id)
    $available=@($status.data.topology|Where-Object {-not $_.allocated -or $_.allocatedToTargetProcess})
    if($available.Count -lt 2){throw 'This PC exposes fewer than two usable CPU Set IDs.'}
    return [uint32]$available[1].id
}

function Invoke-ClaimsCpuSets([Diagnostics.Process]$Process,[uint32]$CpuSetId){
    $directory=Join-Path $script:policyParent ('operations\cpu-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $preview=Join-Path $directory 'preview.json'
    $journal=Join-Path $directory 'journal.json'
    $cpuScript=Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1'
    $previewed=Read-ClaimsOutput (& $cpuScript -Action Preview -TargetProcessId $Process.Id -CpuSetId $CpuSetId -OutputPath $preview)
    if($previewed.status -ne 'preview'){throw ('CPU selection preview failed: '+($previewed.errors|ConvertTo-Json -Compress -Depth 6))}
    $applied=Read-ClaimsOutput (& $cpuScript -Action Apply -InputPath $preview -ReviewSha256 (Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash -JournalPath $journal -ConfirmApply)
    return [pscustomobject]@{journal=$journal;status=$applied.status;errors=$applied.errors}
}

function Invoke-ClaimsChildCpuSets([Diagnostics.Process]$Process,[uint32]$CpuSetId){
    $directory=Join-Path $script:policyParent ('operations\cpu-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $body=@'
$cpuScript=Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1'
$preview=(@(& $cpuScript -Action Preview -TargetProcessId ([int]$processId) -CpuSetId ([uint32]$cpuSetId) -OutputPath $previewPath) -join "`n")|ConvertFrom-Json
$applied=$null
if($preview.status -eq 'preview'){$applied=(@(& $cpuScript -Action Apply -InputPath $previewPath -ReviewSha256 (Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash -JournalPath $journalPath -ConfirmApply) -join "`n")|ConvertFrom-Json}
[IO.File]::WriteAllText($resultPath,(@{preview=$preview.status;status=$(if($applied){$applied.status}else{$preview.status});errors=$(if($applied){$applied.errors}else{$preview.errors})}|ConvertTo-Json -Depth 8 -Compress))
'@
    return Invoke-ClaimsChild $body @{processId=$Process.Id;cpuSetId=$CpuSetId;previewPath=(Join-Path $directory 'preview.json');journalPath=(Join-Path $directory 'journal.json')}
}

function Set-ClaimsReadDenied([string]$Path,[bool]$Denied){
    $file=[IO.FileInfo]::new($Path)
    $security=$file.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.AccessControlType]::Deny)
    if($Denied){$security.AddAccessRule($rule)}else{[void]$security.RemoveAccessRule($rule)}
    $file.SetAccessControl($security)
}

function Test-ScenarioClaimsApplyOnceFirst {
    $path=Copy-Probe 'ClaimsApplyOnce.exe'
    $probe=Start-Probe $path
    $other=Join-Path (Join-Path $script:scenarioRoot 'elsewhere') 'ClaimsApplyOnce.exe'
    $applied=Invoke-ClaimsApplyOnce $probe @{cpuPriority='BelowNormal'}
    Assert ($applied.status -eq 'applied' -and (Read-Field $probe 'cpuPriority') -eq 'BelowNormal') 'Apply once lowered the probe CPU priority and kept its journal in the data operations folder'
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})} 'Undo the Apply once change on ClaimsApplyOnce.exe (or close ClaimsApplyOnce.exe) first' 'A path rule for the same CPU priority is refused while Apply once holds it'
    Assert-Refused {Save-ClaimsRule (New-Rule $other @{cpuPriority='High'} -MatchMode 'filename')} 'Undo the Apply once change on ClaimsApplyOnce.exe (or close ClaimsApplyOnce.exe) first' 'A file-name rule from another folder is refused for the same running app'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'BelowNormal' -and @(Get-ChildItem -LiteralPath (Join-Path $script:policyRoot 'rules') -Filter '*.json' -ErrorAction SilentlyContinue).Count -eq 0) 'Refused saves wrote no rule and left the Apply once value in place'
    $unrelated=New-Rule $path @{ioPriority=1}
    Save-ClaimsRule $unrelated|Out-Null
    Assert $true 'A rule for a setting Apply once did not change is still allowed'
    Remove-ClaimsRule $unrelated
    $elsewhere=New-Rule $other @{cpuPriority='High'}
    Save-ClaimsRule $elsewhere|Out-Null
    Assert $true 'A path rule for a different folder with the same file name is not blocked'
    Remove-ClaimsRule $elsewhere
    Assert ((Restore-ClaimsApplyOnce $applied.journal) -eq 'restored' -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'Undo restored the original CPU priority'
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})|Out-Null
    Assert $true 'After undo the same rule saves'
}

function Test-ScenarioClaimsExitedProcessIgnored {
    $path=Copy-Probe 'ClaimsExited.exe'
    $probe=Start-Probe $path
    $applied=Invoke-ClaimsApplyOnce $probe @{cpuPriority='BelowNormal'}
    Assert ($applied.status -eq 'applied') 'Apply once changed the probe'
    $probe.Kill();$probe.WaitForExit(10000)|Out-Null
    $journal=(Read-RooIndustriesOperationJson $applied.journal).data
    Assert ($journal.status -eq 'applied') 'The journal still says applied after the process exited'
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})|Out-Null
    Assert $true 'A record for an exited process does not block the rule'
}

function Test-ScenarioClaimsCpuSelectionFirst {
    $path=Copy-Probe 'ClaimsCpuSelection.exe'
    $probe=Start-Probe $path
    $id=Get-ClaimsCpuSetId $probe
    $applied=Invoke-ClaimsCpuSets $probe $id
    Assert ($applied.status -eq 'applied' -and (Read-Field $probe 'cpuSets') -eq [string]$id) 'CPU selection assigned a CPU Set to the probe'
    $choice=Get-TopologyChoice $probe
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{} -CpuSelection $choice.selection)} 'Undo the CPU selection change on ClaimsCpuSelection.exe (or close ClaimsCpuSelection.exe) first' 'A Preferred CPUs rule is refused while CPU selection holds the probe'
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})|Out-Null
    Assert $true 'A CPU priority rule is not blocked by CPU selection'
    $restored=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1') -Action Restore -JournalPath $applied.journal -ConfirmApply)
    Assert ($restored.status -eq 'restored') 'CPU selection undo restored the probe'
    Save-ClaimsRule (New-Rule $path @{} -CpuSelection $choice.selection)|Out-Null
    Assert $true 'After undo the Preferred CPUs rule saves'
}

function Test-ScenarioClaimsGamePriorityFirst {
    $name='ClaimsGame.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $profile=New-ClaimsProfile $name 'game'
    $session=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Start-GameTuneSession.ps1') -ProfilePath $profile -StateRoot $state -MaxDurationSeconds 1 -PollIntervalSeconds 1 -ConfirmApply)
    Note 'gameTuneSession' @{status=$session.status;restorable=$session.restorable;sessionPath=$session.sessionPath;changed=@($session.changedItems).Count;skipped=@($session.skippedItems|ForEach-Object {$_.reason})}
    Assert ($session.restorable -eq $true -and (Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'Game priority raised the probe and left a restorable session'
    $bytes=[IO.File]::ReadAllBytes($session.sessionPath)
    Note 'sessionStartsWithBom' ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} 'Undo the Game priority change on ClaimsGame.exe (or close ClaimsGame.exe) first' 'A CPU priority rule is refused while Game priority holds the probe'
    $io=New-Rule $path @{ioPriority=1}
    Save-ClaimsRule $io $script:policyRoot $repo|Out-Null
    Assert $true 'A rule for a setting Game priority did not change is still allowed'
    Remove-ClaimsRule $io
    $stopped=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Stop-GameTuneSession.ps1') -SessionPath $session.sessionPath -BackupPath $session.backupManifestPath -StateRoot $state -ConfirmApply)
    Assert ($stopped.restorable -eq $false -and (Read-Field $probe 'cpuPriority') -eq 'Normal') 'Game priority undo restored the probe'
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo|Out-Null
    Assert $true 'After undo the CPU priority rule saves'
}

function Test-ScenarioClaimsBackgroundPrioritiesFirst {
    $name='ClaimsBackground.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $profile=New-ClaimsProfile $name 'background'
    $applied=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Apply-ProcessProfile.ps1') -ProfilePath $profile -StateRoot (Join-Path $repo 'backend\state') -ConfirmApply)
    Note 'backgroundApply' @{status=$applied.status;backup=$applied.backup}
    Assert ($applied.backup.location -and (Read-Field $probe 'cpuPriority') -eq 'BelowNormal') 'Background priorities lowered the probe and wrote a backup'
    $pointer=Join-Path $script:policyParent 'settings\process-profile-recovery.json'
    [IO.Directory]::CreateDirectory((Split-Path $pointer -Parent))|Out-Null
    [IO.File]::WriteAllText($pointer,(@{path=[string]$applied.backup.location;id=[string]$applied.backup.backupId;generation=[Guid]::NewGuid().ToString('N')}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})} 'Undo the Background priorities change on ClaimsBackground.exe (or close ClaimsBackground.exe) first' 'A CPU priority rule is refused while Background priorities holds the probe'
    Set-Field $probe 'cpuPriority' 'Normal'
    $rule=New-Rule $path @{cpuPriority='High'}
    Save-ClaimsRule $rule|Out-Null
    Assert $true 'With the recovery pointer still present, a probe already back at its original value does not block'
    Remove-ClaimsRule $rule
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    $restored=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Restore-ProcessProfileBackup.ps1') -BackupPath $applied.backup.location -ConfirmApply)
    Note 'backgroundRestore' $restored.status
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal') 'Background priorities undo restored the probe'
    Remove-Item -LiteralPath $pointer
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})|Out-Null
    Assert $true 'After undo clears the recovery pointer the rule saves'
}

function Test-ScenarioClaimsBackgroundLimitsFirst {
    $name='ClaimsLimits.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $directory=Join-Path $repo 'backend\state\process-governor-sessions\process-governor-claims-scenario'
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    $captured=[DateTime]::UtcNow.ToString('o')
    $snapshot=[ordered]@{processId=$probe.Id;processName=$name;executablePath=$path;originalPriorityClass='Normal';proposedPriorityClass='BelowNormal'
        controlChanges=@([ordered]@{control='priorityClass';currentValue='Normal';proposedValue='BelowNormal'});processStartTimeUtc=$probe.StartTime.ToUniversalTime().ToString('o');capturedAtUtc=$captured;sessionId='process-governor-claims-scenario'}
    $write={param($Session,$Backup)
        ($Session|ConvertTo-Json -Depth 12)|Set-Content -LiteralPath (Join-Path $directory 'session.json') -Encoding UTF8
        ($Backup|ConvertTo-Json -Depth 12)|Set-Content -LiteralPath (Join-Path $directory 'backup.json') -Encoding UTF8}
    $session=[ordered]@{sessionId='process-governor-claims-scenario';status='completed';sessionStatus='completed';restorable=$true;activeRestraints=@([ordered]@{processId=$probe.Id;processName=$name;executablePath=$path;snapshot=$snapshot});restoredItems=@()}
    & $write $session ([ordered]@{sessionId='process-governor-claims-scenario';snapshots=@($snapshot)})
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} 'Undo the Background limits change on ClaimsLimits.exe (or close ClaimsLimits.exe) first' 'A CPU priority rule is refused while a Background limits restraint holds the probe (fabricated session record)'
    $stale=[ordered]@{};foreach($key in $snapshot.Keys){$stale[$key]=$snapshot[$key]}
    $stale.processStartTimeUtc=$probe.StartTime.ToUniversalTime().AddSeconds(-30).ToString('o')
    & $write ([ordered]@{sessionId='process-governor-claims-scenario';status='completed';restorable=$true;activeRestraints=@([ordered]@{processId=$probe.Id;snapshot=$stale});restoredItems=@()}) ([ordered]@{snapshots=@($stale)})
    $rule=New-Rule $path @{cpuPriority='High'}
    Save-ClaimsRule $rule $script:policyRoot $repo|Out-Null
    Assert $true 'A record whose start time belongs to an earlier process with the same ID does not block'
    Remove-ClaimsRule $rule
    & $write ([ordered]@{sessionId='process-governor-claims-scenario';status='running';restorable=$true;activeRestraints=@();restoredItems=@()}) ([ordered]@{snapshots=@($snapshot)})
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} 'Undo the Background limits change on ClaimsLimits.exe (or close ClaimsLimits.exe) first' 'A running session whose backup still holds the probe refuses'
    Set-Field $probe 'cpuPriority' 'Normal'
    $rule=New-Rule $path @{cpuPriority='High'}
    Save-ClaimsRule $rule $script:policyRoot $repo|Out-Null
    Assert $true 'Once the probe is back at its original value the record no longer blocks'
    Remove-ClaimsRule $rule
    Set-Field $probe 'cpuPriority' 'High'
    $rule=New-Rule $path @{cpuPriority='High'}
    Save-ClaimsRule $rule $script:policyRoot $repo|Out-Null
    Assert $true 'A value changed by someone else, which Background limits would preserve, does not block'
    Remove-ClaimsRule $rule
    Set-Field $probe 'cpuPriority' 'BelowNormal'
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})|Out-Null
    Assert $true 'Session records are read from the requesting app backend only'
}

function Test-ScenarioClaimsRuleFirst {
    Initialize-ClaimsRedirect
    $name='ClaimsRuleFirst.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:claimsRules|Out-Null
    Assert-Refused {Invoke-ClaimsApplyOnce $probe @{cpuPriority='BelowNormal'} $script:claimsRules} 'Managed by the governor' 'Apply once refuses a field an enabled rule owns'
    $game=Invoke-ClaimsFeature 'Start-GameTuneSession.ps1' @{ProfilePath=(New-ClaimsProfile $name 'game');StateRoot=(Join-Path $repo 'backend\state');MaxDurationSeconds=1;PollIntervalSeconds=1;ConfirmApply=$true}
    Note 'gameSkipped' @($game.skippedItems|ForEach-Object {$_.reason})
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal' -and @($game.skippedItems|Where-Object {$_.reason -like '*Managed by the governor*'}).Count -gt 0) 'Game priority skips the CPU priority a rule owns'
    $background=Invoke-ClaimsFeature 'Apply-ProcessProfile.ps1' @{ProfilePath=(New-ClaimsProfile $name 'background');StateRoot=(Join-Path $repo 'backend\state');ConfirmApply=$true}
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal' -and ($background|ConvertTo-Json -Depth 12) -like '*Managed by the governor*') 'Background priorities skips the CPU priority a rule owns'
    $id=Get-ClaimsCpuSetId $probe
    $applied=Invoke-ClaimsChildCpuSets $probe $id
    Note 'cpuSelection' $applied
    Assert ($applied.status -eq 'applied' -and (Read-Field $probe 'cpuSets') -eq [string]$id) 'CPU selection still changes a field the rule does not own'
}

function Test-ScenarioClaimsGovernorValueNotBlamed {
    Initialize-ClaimsRedirect
    $name='ClaimsBlame.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $rule=New-Rule $path @{cpuPriority='High'}
    Save-ClaimsRule $rule $script:claimsRules $repo|Out-Null
    Set-Field $probe 'cpuPriority' 'High'
    $game=Invoke-ClaimsFeature 'Start-GameTuneSession.ps1' @{ProfilePath=(New-ClaimsProfile $name 'game' 'Low');StateRoot=(Join-Path $repo 'backend\state');MaxDurationSeconds=1;PollIntervalSeconds=1;ConfirmApply=$true}
    Note 'gameSession' @{restorable=$game.restorable;skipped=@($game.skippedItems|ForEach-Object {$_.reason})}
    Assert ($game.restorable -eq $true -and (Read-Field $probe 'cpuPriority') -eq 'High' -and (Read-Field $probe 'ioPriority') -eq 1) 'Game priority changed only I/O priority and recorded the rule value High as the CPU priority original'
    Set-Field $probe 'cpuPriority' 'AboveNormal'
    $rule.controls=@{cpuPriority='AboveNormal'}
    Save-ClaimsRule $rule $script:claimsRules $repo|Out-Null
    Assert $true 'Editing the rule is not blamed on Game priority for a CPU priority Game priority never changed'
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{ioPriority=2}) $script:claimsRules $repo} 'Undo the Game priority change on ClaimsBlame.exe (or close ClaimsBlame.exe) first, or save this rule without I/O priority' 'An I/O priority rule is still refused while Game priority holds I/O priority'
}

function Test-ScenarioClaimsPausedRuleOwned {
    Initialize-ClaimsRedirect
    $name='ClaimsPaused.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $choice=Get-TopologyChoice $probe
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'} -CpuSelection $choice.selection) $script:claimsRules|Out-Null
    Core 'policy-pause' @{paused=$true} $script:claimsRules|Out-Null
    Assert ((Core 'policy-summary' @{} $script:claimsRules).paused -eq $true) 'The governor is paused'
    $background=Invoke-ClaimsFeature 'Apply-ProcessProfile.ps1' @{ProfilePath=(New-ClaimsProfile $name 'background');StateRoot=(Join-Path $repo 'backend\state');ConfirmApply=$true}
    Note 'backgroundStatus' $background.status
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal' -and ($background|ConvertTo-Json -Depth 12) -like '*Managed by the governor*') 'Background priorities still skips the CPU priority of a paused rule'
    $cpu=Invoke-ClaimsChildCpuSets $probe (Get-ClaimsCpuSetId $probe)
    Note 'cpuSelection' $cpu
    Assert ($cpu.status -eq 'failed' -and ($cpu.errors|ConvertTo-Json -Depth 6) -like '*Managed by the governor*' -and (Read-Field $probe 'cpuSets') -eq '') 'CPU selection still refuses the Preferred CPUs of a paused rule'
    Assert-Refused {Invoke-ClaimsApplyOnce $probe @{cpuPriority='BelowNormal'} $script:claimsRules} 'Managed by the governor' 'Apply once still refuses the CPU priority of a paused rule'
}

function Test-ScenarioClaimsResumeRefused {
    $path=Copy-Probe 'ClaimsResume.exe'
    $probe=Start-Probe $path
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'})|Out-Null
    Core 'policy-pause' @{paused=$true}|Out-Null
    $unowned=Join-Path $script:scenarioRoot 'unowned-rules'
    $applied=Invoke-ClaimsApplyOnce $probe @{cpuPriority='BelowNormal'} $unowned
    Assert ($applied.status -eq 'applied') 'Apply once changed the probe through a rules folder without that rule'
    Assert-Refused {Core 'policy-pause' @{paused=$false}} 'Undo the Apply once change on ClaimsResume.exe (or close ClaimsResume.exe) first' 'Resuming is refused while Apply once holds a field of a paused rule'
    Assert ((Core 'policy-summary').paused -eq $true -and (Read-Field $probe 'cpuPriority') -eq 'BelowNormal') 'The refused resume left the governor paused and the probe untouched'
    Assert ((Restore-ClaimsApplyOnce $applied.journal $unowned) -eq 'restored') 'Apply once undo restored the probe'
    Core 'policy-pause' @{paused=$false}|Out-Null
    Assert ((Core 'policy-summary').paused -eq $false) 'After undo the governor resumes'
}

function Start-ClaimsHostState {
    Initialize-ClaimsRedirect
    $path=Copy-Probe 'ClaimsHostState.exe'
    $owner=Start-Probe $path
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:claimsRules|Out-Null
    Core 'policy-run' @{durationSeconds=3} $script:claimsRules|Out-Null
    $hostState=Join-Path $script:claimsRules 'host.json'
    Assert (Test-Path -LiteralPath $hostState) 'The governor wrote its host state'
    return [pscustomobject]@{hostState=$hostState;path=$path;probe=$owner}
}

function Invoke-ClaimsHeldApply($Setup,[string]$Name,[string]$Label,[scriptblock]$Hold,[scriptblock]$Release,[int]$Milliseconds){
    $path=Copy-Probe $Name
    $probe=Start-Probe $path
    $id=Get-ClaimsCpuSetId $probe
    $directory=Join-Path $script:policyParent ('operations\cpu-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $ready=Join-Path $script:scenarioRoot ('ready-'+$Name)
    $go=Join-Path $script:scenarioRoot ('go-'+$Name)
    $body=@'
. (Join-Path $scriptsRoot 'CpuSets.Common.ps1')
Initialize-RooIndustriesCpuSets
$cpuScript=Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1'
$preview=(@(& $cpuScript -Action Preview -TargetProcessId ([int]$processId) -CpuSetId ([uint32]$cpuSetId) -OutputPath $previewPath) -join "`n")|ConvertFrom-Json
if($preview.status -ne 'preview'){throw ('Preview failed: '+($preview.errors|ConvertTo-Json -Compress -Depth 6))}
$hash=(Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash
[IO.File]::WriteAllText($readyPath,'ready')
Wait-Signal $goPath 120
$clock=[Diagnostics.Stopwatch]::StartNew()
$applied=(@(& $cpuScript -Action Apply -InputPath $previewPath -ReviewSha256 $hash -JournalPath $journalPath -ConfirmApply) -join "`n")|ConvertFrom-Json
[IO.File]::WriteAllText($resultPath,(@{status=$applied.status;errors=$applied.errors;elapsedMs=$clock.ElapsedMilliseconds}|ConvertTo-Json -Depth 8 -Compress))
'@
    $child=Start-ClaimsChild $body @{processId=$probe.Id;cpuSetId=$id;previewPath=(Join-Path $directory 'preview.json');journalPath=(Join-Path $directory 'journal.json');readyPath=$ready;goPath=$go}
    $null=Wait-Until {(Test-Path -LiteralPath $ready) -or $child.process.HasExited} 180 50
    if(-not (Test-Path -LiteralPath $ready)){return Wait-ClaimsChild $child}
    $held=& $Hold $Setup.hostState
    try {
        [IO.File]::WriteAllText($go,'go')
        Start-Sleep -Milliseconds $Milliseconds
    } finally {& $Release $Setup.hostState $held}
    $result=Wait-ClaimsChild $child
    Note ($Name+' apply') @{status=$result.status;elapsedMs=$result.elapsedMs;errors=$result.errors}
    Assert ($result.elapsedMs -ge 700) ('The apply waited for host.json, so its ownership read overlapped the '+$Milliseconds+' ms hold')
    Assert ($result.status -eq 'applied' -and (Read-Field $probe 'cpuSets') -eq [string]$id) ('CPU selection on a field no rule owns succeeds while host.json is '+$Label+' for '+$Milliseconds+' ms')
}

function Test-ScenarioClaimsHostStateDeniedBriefly {
    $setup=Start-ClaimsHostState
    $script:cleanups.Add({Set-ClaimsReadDenied (Join-Path $script:claimsRules 'host.json') $false})
    Invoke-ClaimsHeldApply $setup 'ClaimsDenied.exe' 'unreadable (access denied)' {param($Path) Set-ClaimsReadDenied $Path $true} {param($Path,$Held) Set-ClaimsReadDenied $Path $false} 1000
}

function Test-ScenarioClaimsHostStateLockedBriefly {
    $setup=Start-ClaimsHostState
    Invoke-ClaimsHeldApply $setup 'ClaimsLocked.exe' 'locked with no sharing' {param($Path) Hold-File $Path 0} {param($Path,$Held) $Held.stream.Dispose()} 1000
}

function Test-ScenarioClaimsHostStateFailsClosed {
    $setup=Start-ClaimsHostState
    $script:cleanups.Add({Set-ClaimsReadDenied (Join-Path $script:claimsRules 'host.json') $false})
    $ready=Join-Path $script:scenarioRoot 'ready';$go=Join-Path $script:scenarioRoot 'go';$first=Join-Path $script:scenarioRoot 'first';$released=Join-Path $script:scenarioRoot 'released'
    $body=@'
. (Join-Path $scriptsRoot 'GovernorOwnership.Common.ps1')
[IO.File]::WriteAllText($readyPath,'ready')
Wait-Signal $goPath 120
$clock=[Diagnostics.Stopwatch]::StartNew()
$one=@(Get-RooIndustriesGovernorOwnedControls -ProcessId ([int]$processId) -ExecutablePath $probePath -CreationTimeFileTimeUtc $created)
$oneMs=$clock.ElapsedMilliseconds
[IO.File]::WriteAllText($firstPath,'first')
Wait-Signal $releasedPath 60
$clock.Restart()
$two=@(Get-RooIndustriesGovernorOwnedControls -ProcessId ([int]$processId) -ExecutablePath $probePath -CreationTimeFileTimeUtc $created)
[IO.File]::WriteAllText($resultPath,(@{first=$one;firstMs=$oneMs;second=$two;secondMs=$clock.ElapsedMilliseconds}|ConvertTo-Json -Compress))
'@
    $child=Start-ClaimsChild $body @{processId=$setup.probe.Id;probePath=$setup.path;created=[string]$setup.probe.StartTime.ToUniversalTime().ToFileTimeUtc();readyPath=$ready;goPath=$go;firstPath=$first;releasedPath=$released}
    $null=Wait-Until {(Test-Path -LiteralPath $ready) -or $child.process.HasExited} 120 50
    Set-ClaimsReadDenied $setup.hostState $true
    try {
        [IO.File]::WriteAllText($go,'go')
        $null=Wait-Until {(Test-Path -LiteralPath $first) -or $child.process.HasExited} 30 10
    } finally {Set-ClaimsReadDenied $setup.hostState $false}
    [IO.File]::WriteAllText($released,'released')
    $result=Wait-ClaimsChild $child
    Note 'ownershipCalls' $result
    Assert (@($result.first).Count -eq 8 -and $result.firstMs -ge 2900) 'A host state that stays unreadable for the whole retry window fails closed after about three seconds'
    $log=Join-Path $script:claimsData 'process-rules\logs\governor.log'
    $text=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
    Note 'governorLog' $text
    Assert ($text -like '*Could not read the saved rules*') 'The fail-closed read is logged'
    Assert ((@($result.second) -join ',') -eq 'cpuPriority') 'The next read right after recovery is not served from the failed result'
}

function New-ClaimsLimitsProfile([string]$ImageName){
    $profile=[ordered]@{schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='claims-limits';name='Claims limits scenario';profileKind='process-governor';risk='low'
        protectedCatalogPath=(Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        governor=[ordered]@{thresholds=[ordered]@{totalCpuPressureThresholdPercent=0;perProcessCpuThresholdPercent=0;timeOverThresholdSeconds=0;minimumRestraintSeconds=600;restoreCpuThresholdPercent=0;cooldownAfterRestoreSeconds=20;maxSessionDurationSeconds=2;pollIntervalSeconds=1}
            restraint=[ordered]@{priorityClass='BelowNormal'};excludeForegroundProcess=$true;protectedProcesses=@()
            candidateSelectors=@([ordered]@{ruleId='claims-limits';enabled=$true;match=[ordered]@{processNames=@($ImageName)};reason='Claims scenario restraint.';reasonCodes=@();risk='low'})}}
    $path=Join-Path $script:scenarioRoot 'profile-limits.json'
    [IO.File]::WriteAllText($path,($profile|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    return $path
}

function Start-ClaimsGateHolder([int]$Milliseconds){
    $id=[Guid]::NewGuid().ToString('N').Substring(0,8)
    $held=Join-Path $script:scenarioRoot ('gate-held-'+$id)
    $released=Join-Path $script:scenarioRoot ('gate-released-'+$id)
    $body=@'
$mutex=[Threading.Mutex]::new($false,'Global\RooIndustriesGovernorGate-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
try {$null=$mutex.WaitOne()} catch {}
[IO.File]::WriteAllText($heldPath,[DateTime]::UtcNow.ToString('o'))
Start-Sleep -Milliseconds ([int]$hold)
[IO.File]::WriteAllText($releasedPath,[DateTime]::UtcNow.ToString('o'))
$mutex.ReleaseMutex()
[IO.File]::WriteAllText($resultPath,'{"released":true}')
'@
    $child=Start-ClaimsChild $body @{heldPath=$held;releasedPath=$released;hold=$Milliseconds}
    $null=Wait-Until {(Test-Path -LiteralPath $held) -or $child.process.HasExited} 30 20
    if(-not (Test-Path -LiteralPath $held)){Wait-ClaimsChild $child|Out-Null;throw 'The gate holder did not take the governor gate.'}
    return [pscustomobject]@{child=$child;held=$held;released=$released}
}

function Get-ClaimsReleasedAt($Holder){return [DateTime]::Parse([IO.File]::ReadAllText($Holder.released),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}

function Watch-ClaimsDuringHold($Holder,[Diagnostics.Process]$Probe,[string]$Field){
    $seen=New-Object System.Collections.Generic.List[string]
    while(-not (Test-Path -LiteralPath $Holder.released)){
        $seen.Add([string](Read-Field $Probe $Field))
        Start-Sleep -Milliseconds 200
    }
    return @($seen|Select-Object -Unique)
}

function Test-ScenarioClaimsGateCpuSelection {
    $path=Copy-Probe 'ClaimsGateCpu.exe'
    $probe=Start-Probe $path
    $id=Get-ClaimsCpuSetId $probe
    $directory=Join-Path $script:policyParent ('operations\cpu-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $preview=Join-Path $directory 'preview.json'
    $cpuScript=Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1'
    $previewed=Read-ClaimsOutput (& $cpuScript -Action Preview -TargetProcessId $probe.Id -CpuSetId $id -OutputPath $preview)
    Assert ($previewed.status -eq 'preview') 'CPU selection previewed the probe'
    $holder=Start-ClaimsGateHolder 6000
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $applied=Read-ClaimsOutput (& $cpuScript -Action Apply -InputPath $preview -ReviewSha256 (Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash -JournalPath (Join-Path $directory 'journal.json') -ConfirmApply)
    $releasedBeforeReturn=Test-Path -LiteralPath $holder.released
    Note 'cpuGate' @{status=$applied.status;elapsedMs=$clock.ElapsedMilliseconds;releasedBeforeReturn=$releasedBeforeReturn}
    Assert ($applied.status -eq 'applied' -and $releasedBeforeReturn -and (Read-Field $probe 'cpuSets') -eq [string]$id) 'CPU selection waited for the governor gate before applying'
    Assert ([DateTime]::Parse([string]$applied.data.updatedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() -ge (Get-ClaimsReleasedAt $holder).ToUniversalTime()) 'Its journal was written after the gate was released'
    Wait-ClaimsChild $holder.child|Out-Null
}

function Test-ScenarioClaimsGateGamePriority {
    $name='ClaimsGateGame.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $holder=Start-ClaimsGateHolder 20000
    $session=Start-ClaimsChild '$output=@(& (Join-Path $scriptsRoot ''Start-GameTuneSession.ps1'') -ProfilePath $profilePath -StateRoot $stateRoot -MaxDurationSeconds 1 -PollIntervalSeconds 1 -ConfirmApply) -join "`n";[IO.File]::WriteAllText($resultPath,$output)' @{profilePath=(New-ClaimsProfile $name 'game');stateRoot=(Join-Path $repo 'backend\state')}
    $during=Watch-ClaimsDuringHold $holder $probe 'cpuPriority'
    $result=Wait-ClaimsChild $session
    $changedAt=@($result.changedItems|ForEach-Object {[DateTime]::Parse([string]$_.changedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()})
    Note 'gameGate' @{during=$during;changedAt=$changedAt;releasedAt=(Get-ClaimsReleasedAt $holder);restorable=$result.restorable}
    Assert ((@($during) -join ',') -eq 'Normal') 'Game priority did not change the probe while a rule change held the governor gate'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'AboveNormal' -and $changedAt.Count -gt 0 -and @($changedAt|Where-Object {$_ -lt (Get-ClaimsReleasedAt $holder).ToUniversalTime()}).Count -eq 0) 'Game priority applied only after the gate was released'
    Wait-ClaimsChild $holder.child|Out-Null
}

function Test-ScenarioClaimsGateBackgroundLimits {
    $name='ClaimsGateLimits.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $holder=Start-ClaimsGateHolder 15000
    $session=Start-ClaimsChild '$output=@(& (Join-Path $scriptsRoot ''Start-ProcessGovernorSession.ps1'') -ProfilePath $profilePath -StateRoot $stateRoot -MaxDurationSeconds 2 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 200 -ConfirmApply) -join "`n";[IO.File]::WriteAllText($resultPath,$output)' @{profilePath=(New-ClaimsLimitsProfile $name);stateRoot=$state}
    $during=Watch-ClaimsDuringHold $holder $probe 'cpuPriority'
    $result=Wait-ClaimsChild $session
    Note 'limitsGate' @{during=$during;status=$result.status;restorable=$result.restorable;changed=@($result.changedItems).Count;warnings=@($result.warnings|ForEach-Object {$_.code})}
    Assert ((@($during) -join ',') -eq 'Normal') 'Background limits did not restrain the probe while a rule change held the governor gate'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'BelowNormal' -and $result.restorable -eq $true) 'Background limits restrained the probe after the gate was released and left a restorable session'
    Assert-Refused {Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo} 'Undo the Background limits change on ClaimsGateLimits.exe' 'A real Background limits session blocks a CPU priority rule for the restrained probe'
    $stopped=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Stop-ProcessGovernorSession.ps1') -SessionPath $result.sessionPath -BackupPath $result.backupManifestPath -StateRoot $state -ConfirmApply)
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal') 'Background limits undo restored the probe'
    Save-ClaimsRule (New-Rule $path @{cpuPriority='High'}) $script:policyRoot $repo|Out-Null
    Assert $true 'After undo the CPU priority rule saves'
    Wait-ClaimsChild $holder.child|Out-Null
}

function Test-ScenarioClaimsGateRaceCpuSelection {
    Initialize-ClaimsRedirect
    $outcomes=New-Object System.Collections.Generic.List[object]
    for($round=1;$round -le 8;$round++){
        $path=Copy-Probe ('ClaimsRace'+$round+'.exe')
        $probe=Start-Probe $path
        $id=Get-ClaimsCpuSetId $probe
        $choice=Get-TopologyChoice $probe
        $directory=Join-Path $script:claimsData ('operations\cpu-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        $preview=Join-Path $directory 'preview.json'
        $journal=Join-Path $directory 'journal.json'
        $previewed=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Invoke-ProcessCpuSets.ps1') -Action Preview -TargetProcessId $probe.Id -CpuSetId $id -OutputPath $preview)
        if($previewed.status -ne 'preview'){throw 'CPU selection preview failed.'}
        $requestPath=Join-Path $script:scenarioRoot ('rule-request-'+$round+'.json')
        if($script:roots -notcontains $script:claimsRules){$script:roots.Add($script:claimsRules)}
        [IO.File]::WriteAllText($requestPath,(@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$script:claimsRules;confirm=$true;rule=(New-Rule $path @{} -CpuSelection $choice.selection)}|ConvertTo-Json -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))
        $go=Join-Path $script:scenarioRoot ('race-go-'+$round)
        $cpu=Start-ClaimsChild '. (Join-Path $scriptsRoot ''CpuSets.Common.ps1'');Initialize-RooIndustriesCpuSets;$hash=(Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash;Wait-Signal $goPath 60;$output=@(& (Join-Path $scriptsRoot ''Invoke-ProcessCpuSets.ps1'') -Action Apply -InputPath $previewPath -ReviewSha256 $hash -JournalPath $journalPath -ConfirmApply) -join "`n";[IO.File]::WriteAllText($resultPath,$output)' @{previewPath=$preview;journalPath=$journal;goPath=$go}
        $save=Start-ClaimsChild '$text=[IO.File]::ReadAllText($requestPath);Wait-Signal $goPath 60;Start-Sleep -Milliseconds ([int]$delay);$output=@($text|& $dotnet $hostDll ''rule-save'' ''-'') -join "`n";[IO.File]::WriteAllText($resultPath,$output)' @{requestPath=$requestPath;goPath=$go;delay=(($round-1)*400);dotnet=$DotNetPath;hostDll=(Join-Path $hostDirectory 'Optimizer.Host.dll')}
        Start-Sleep -Milliseconds 2500
        [IO.File]::WriteAllText($go,'go')
        $cpuResult=Wait-ClaimsChild $cpu
        $saveResult=Wait-ClaimsChild $save
        $ruleSaved=$saveResult.status -eq 'completed'
        $applied=$cpuResult.status -eq 'applied' -and (Read-Field $probe 'cpuSets') -eq [string]$id
        $outcomes.Add([pscustomobject]@{round=$round;saveDelayMs=(($round-1)*400);ruleSaved=$ruleSaved;cpuApplied=$applied;saveError=$saveResult.error.message;cpuErrors=@($cpuResult.errors|ForEach-Object {$_.message})})
    }
    Note 'raceOutcomes' @($outcomes.ToArray())
    Assert (@($outcomes|Where-Object {$_.ruleSaved -and $_.cpuApplied}).Count -eq 0) 'In every round either the rule save or CPU selection won, never both'
    Assert (@($outcomes|Where-Object {-not $_.ruleSaved -and -not $_.cpuApplied}).Count -eq 0) 'In every round one of them succeeded'
    Note 'raceWinners' @{rule=@($outcomes|Where-Object {$_.ruleSaved}).Count;cpuSelection=@($outcomes|Where-Object {$_.cpuApplied}).Count}
}

function Test-ScenarioClaimsGameUndoOnlyRecorded {
    Initialize-ClaimsRedirect
    $name='ClaimsGameUndo.exe'
    $path=Copy-Probe $name
    $probe=Start-Probe $path
    $repo=New-ClaimsRepo
    $state=Join-Path $repo 'backend\state'
    $session=Read-ClaimsOutput (& (Join-Path $scriptsRoot 'Start-GameTuneSession.ps1') -ProfilePath (New-ClaimsProfile $name 'game') -StateRoot $state -MaxDurationSeconds 1 -PollIntervalSeconds 1 -ConfirmApply)
    Assert ($session.restorable -eq $true -and (Read-Field $probe 'cpuPriority') -eq 'AboveNormal') 'Game priority changed only the CPU priority of the probe'
    Save-ClaimsRule (New-Rule $path @{ioPriority=1}) $script:claimsRules $repo|Out-Null
    Set-Field $probe 'ioPriority' 1
    Assert ((Read-Field $probe 'ioPriority') -eq 1) 'A rule owns I/O priority and the probe carries the rule value'
    $stopped=Invoke-ClaimsFeature 'Stop-GameTuneSession.ps1' @{SessionPath=$session.sessionPath;BackupPath=$session.backupManifestPath;StateRoot=$state;ConfirmApply=$true}
    Note 'gameUndo' @{restorable=$stopped.restorable;result=$stopped.result.status;skipped=@($stopped.skippedItems|ForEach-Object {$_.reason})}
    Assert ($stopped.restorable -eq $false -and $stopped.result.status -eq 'rolledBack') 'Game priority undo ends restored, not partial'
    Assert ((Read-Field $probe 'cpuPriority') -eq 'Normal' -and (Read-Field $probe 'ioPriority') -eq 1) 'Undo restored only the CPU priority it changed and left the rule-owned I/O priority alone'
}
