function Invoke-HostLater([string]$CoreAction,[hashtable]$Values,[hashtable]$Environment=@{}){
    $request=@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$script:policyRoot;confirm=$true}
    foreach($key in $Values.Keys){$request[$key]=$Values[$key]}
    $requestFile=Join-Path $script:scenarioRoot ('request-'+[Guid]::NewGuid().ToString('N')+'.json')
    $output=$requestFile+'.out'
    [IO.File]::WriteAllText($requestFile,($request|ConvertTo-Json -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))
    $script=('Get-Content -LiteralPath ''{0}'' -Raw | & ''{1}'' ''{2}'' {3} - *> ''{4}''' -f $requestFile,$DotNetPath,(Join-Path $hostDirectory 'Optimizer.Host.dll'),$CoreAction,$output)
    foreach($key in $Environment.Keys){Set-Item -LiteralPath ('Env:\'+$key) -Value $Environment[$key]}
    try {$process=Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))) -WindowStyle Hidden -PassThru}
    finally {foreach($key in $Environment.Keys){Remove-Item -LiteralPath ('Env:\'+$key) -ErrorAction SilentlyContinue}}
    $script:probes.Add($process)
    return [pscustomobject]@{process=$process;output=$output}
}

function Read-HostLater($Call){
    $Call.process.WaitForExit(60000)|Out-Null
    if(-not (Test-Path -LiteralPath $Call.output)){return $null}
    return ((Get-Content -LiteralPath $Call.output -Raw)|ConvertFrom-Json)
}

function New-GameContext([string]$Folder='game',[string]$Controls='{"gpuPriority":3}'){
    $directory=Join-Path $script:scenarioRoot $Folder
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $game=Join-Path $directory 'RooIndustriesGovernorGame.exe'
    $launcher=Join-Path $directory 'RooIndustriesGovernorLauncher.exe'
    Copy-Item -LiteralPath (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -Destination $game
    Copy-Item -LiteralPath (Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe') -Destination $launcher
    $process=Start-Probe $launcher '900'
    $controlsFile=Join-Path $directory 'controls.json'
    [IO.File]::WriteAllText($controlsFile,$Controls,[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{game=$game;launcher=$process;controls=$controlsFile}
}

function New-GameSession($Context){
    $operations=Join-Path $script:policyParent 'operations'
    Core 'operations-secure' @{operationsRoot=$operations}|Out-Null
    $directory=Join-Path $operations ('game-session-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $file=Join-Path $directory 'preview.json'
    $result=(@(& (Join-Path $scriptsRoot 'Invoke-ProtectedGameSession.ps1') -Action Preview -LauncherProcessId $Context.launcher.Id -GamePath $Context.game -ControlsPath $Context.controls -PreviewPath $file -AcceptLauncherScope -HostDirectory $hostDirectory -DotNetPath $DotNetPath) -join "`n")|ConvertFrom-Json
    if($result.status -ne 'completed'){throw ('Game session preview failed: '+(@($result.errors|ForEach-Object {$_.message}) -join '; ')+$result.error.message)}
    $session=[pscustomobject]@{file=$file;hash=$result.data.reviewHash;root=(Join-Path $directory 'session')}
    $stop={try {& (Join-Path $scriptsRoot 'Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot $session.root -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply|Out-Null} catch {}}.GetNewClosure()
    $script:cleanups.Add({if(Test-Path -LiteralPath (Join-Path $session.root 'session.json')){& $stop}}.GetNewClosure())
    return $session
}

function Start-GameSession($Session,[switch]$Later){
    $arguments=@{Action='Start';PreviewPath=$Session.file;ReviewHash=$Session.hash;SessionRoot=$Session.root;HostDirectory=$hostDirectory;DotNetPath=$DotNetPath;ConfirmApply=$true}
    if(-not $Later){return & (Join-Path $scriptsRoot 'Invoke-ProtectedGameSession.ps1') @arguments}
    $script=('& ''{0}'' -Action Start -PreviewPath ''{1}'' -ReviewHash ''{2}'' -SessionRoot ''{3}'' -HostDirectory ''{4}'' -DotNetPath ''{5}'' -ConfirmApply *> ''{6}''' -f (Join-Path $scriptsRoot 'Invoke-ProtectedGameSession.ps1'),$Session.file,$Session.hash,$Session.root,$hostDirectory,$DotNetPath,($Session.root+'.start.log'))
    $process=Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))) -WindowStyle Hidden -PassThru
    $script:probes.Add($process)
    return $process
}

function Test-ScenarioOtherAccount {
    $path=Copy-Probe 'RooIndustriesGovernorOther.exe' 'other'
    $system=Start-SystemProcess $path '900'
    $before=[string]$system.PriorityClass
    Save-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Other account' 'filename')|Out-Null
    Worker 'Sync'|Out-Null
    Start-Sleep -Seconds 4
    $issues=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $system.Id})
    $system.Refresh()
    Note 'otherAccount' ([ordered]@{issues=$issues;errors=@((Get-GovernorState).errors);before=$before;after=[string]$system.PriorityClass})
    Assert ($issues.Count -ge 1 -and $issues[0].kind -eq 'otherAccount' -and $issues[0].message -eq "Running under another Windows account, so this rule doesn't control it.") 'A matching app under another Windows account is reported as such, not as unavailable'
    Assert ([string]$system.PriorityClass -eq $before) 'The other account''s app is left unchanged'
    $rule=@(Core 'rules-list')[0]
    $pathRule=New-Rule $path @{cpuPriority='AboveNormal'} 'Other account by path' 'path'
    $pathRule.ruleId=$rule.ruleId
    Save-Rule $pathRule|Out-Null
    Start-Sleep -Seconds 3
    $byPath=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $system.Id})
    Note 'otherAccountByPath' $byPath
    Assert ($byPath.Count -ge 1 -and $byPath[0].kind -eq 'otherAccount' -and $byPath[0].executablePath -eq $path) 'A path rule names the other account''s app at its own path'
}

function Test-ScenarioOtherAccountElsewhere {
    $path=Copy-Probe 'RooIndustriesGovernorOther.exe' 'other'
    $system=Start-SystemProcess $path '900'
    Save-Rule (New-Rule (Join-Path $script:scenarioRoot 'elsewhere\RooIndustriesGovernorOther.exe') @{cpuPriority='AboveNormal'} 'Same name elsewhere' 'path')|Out-Null
    Worker 'Sync'|Out-Null
    Start-Sleep -Seconds 4
    $unrelated=@((Get-GovernorState).issues|Where-Object {$_.processId -eq $system.Id})
    Note 'otherAccountElsewhere' $unrelated
    Assert ($unrelated.Count -eq 0) 'A path rule for another folder says nothing about a same-named app of another account that it would never control'
}

function Test-ScenarioForeignRecord {
    $dummy=Copy-Probe 'RooIndustriesGovernorDummy.exe' 'dummy'
    Save-Rule (New-Rule $dummy @{cpuPriority='AboveNormal'} 'Unrelated rule')|Out-Null
    Worker 'Sync'|Out-Null
    $own=Start-Probe (Copy-Probe)
    $otherPath=Copy-Probe 'RooIndustriesGovernorOther.exe' 'other'
    $system=Start-SystemProcess $otherPath '900'
    Worker 'Pause'|Out-Null
    $operation=Join-Path $script:policyRoot ('operations\'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    $template=Core 'process-preview' @{processId=$own.Id;controls=@{memoryPriority=3};outputPath=(Join-Path $script:scenarioRoot 'template-preview.json')} (Join-Path $script:scenarioRoot 'unrelated-rules')
    $template.identity.processId=$system.Id
    $template.identity.creationTimeFileTimeUtc=[string]$system.StartTime.ToUniversalTime().ToFileTimeUtc()
    $template.identity.executablePath=$otherPath
    Write-RooIndustriesOperationJson $template $preview
    $hash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash
    $original=$template.original.memoryPriority.value
    [RooIndustriesGovernorScenarioOracle]::SetMemory($system.Handle,3)
    $journal=Join-Path $operation 'journal.json'
    Write-RooIndustriesOperationJson ([ordered]@{schemaVersion=1;preview=$template;reviewHash=$hash;previewPath=$preview;status='applied';updatedAtUtc=[DateTime]::UtcNow.ToString('o');changes=@([ordered]@{name='memoryPriority';original=$original;desired=3;status='applied';observed=3;error=$null})}) $journal
    $statePath=Join-Path $script:policyRoot 'host.json'
    $state=(Read-RooIndustriesOperationJson $statePath).data
    $state.instances=@($state.instances)+@([ordered]@{ruleId=[Guid]::NewGuid().ToString('N');ruleHash=('A'*64);process=$template.identity;previewPath=$preview;reviewHash=$hash;journalPath=$journal;status='active';error=$null})
    Write-RooIndustriesOperationJson $state $statePath
    Worker 'Resume'|Out-Null
    $record=$null
    $null=Wait-Until {$script:foreign=@(Get-Records $system.Id|Where-Object {$_.status -ne 'active'});$script:foreign.Count -gt 0} 15 500
    $record=@($script:foreign)[0]
    Note 'foreignRecord' ([ordered]@{record=$record;memoryPriority=[RooIndustriesGovernorScenarioOracle]::Memory($system.Handle)})
    Assert ($null -ne $record -and $record.status -eq 'conflict' -and $record.error -eq 'This record points at a process of another Windows account, so Roo Industries did not change it.') 'A saved record that points at another account''s process is refused before any write'
    Assert ([RooIndustriesGovernorScenarioOracle]::Memory($system.Handle) -eq 3) 'The other account''s process keeps its value'
}

function Test-ScenarioMigrationRace {
    $legacy=$script:policyRoot
    [IO.Directory]::CreateDirectory((Join-Path $legacy 'rules'))|Out-Null
    $rule=New-Rule (Copy-Probe) @{cpuPriority='AboveNormal'} 'Migrated during a race'
    $rule.revision=[Guid]::NewGuid().ToString('N')
    $ruleFile=Join-Path $legacy ('rules\'+$rule.ruleId+'.json')
    Write-RooIndustriesOperationJson $rule $ruleFile
    $before=(Get-FileHash -LiteralPath $ruleFile).Hash
    $script:roots.Add($legacy)
    $call=Invoke-HostLater 'policy-secure' @{} @{ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS='5000'}
    $moved=Wait-Until {-not (Test-Path -LiteralPath $legacy)} 20 20
    Assert ($null -ne $moved) 'The migration moved the earlier folder away'
    [IO.Directory]::CreateDirectory($legacy)|Out-Null
    $result=Read-HostLater $call
    $folders=@(Get-ChildItem -LiteralPath $script:policyParent -Directory|ForEach-Object {$_.Name})
    $kept=@(Get-ChildItem -LiteralPath $script:policyParent -Recurse -File -Filter ($rule.ruleId+'.json') -ErrorAction SilentlyContinue|Where-Object {(Get-ExposedWriters $_.Directory.Parent.FullName).Count -eq 0 -and (Get-ExposedWriters $_.Directory.FullName).Count -eq 0})
    $after=if(Test-Path -LiteralPath $ruleFile){(Get-FileHash -LiteralPath $ruleFile).Hash}else{$null}
    Note 'migrationRace' ([ordered]@{status=$result.status;error=$result.error.message;folders=$folders;protectedCopies=@($kept|ForEach-Object {$_.FullName});hashBefore=$before;hashAfter=$after})
    Assert ($kept.Count -ge 1) 'The protected copy of the rules is never deleted when the folder is recreated between the two moves'
    Assert ($result.status -eq 'completed' -and $after -eq $before -and (Core 'policy-summary').secured -and (Get-ExposedWriters $legacy).Count -eq 0) 'The protected copy is already the rules folder when the call returns, with the rule byte for byte as before'
    Assert (@($folders|Where-Object {$_ -like 'process-rules.untrusted-*'}).Count -ge 1 -and @($folders|Where-Object {$_ -like 'process-rules.secure-*' -or $_ -like 'process-rules.legacy-*' -or $_ -like 'process-rules.stray-*'}).Count -eq 0) 'The folder recreated in between is set aside as untrusted, and no half-finished copy is left behind'
}

function Test-ScenarioMigrationRacePlanted {
    $legacy=$script:policyRoot
    [IO.Directory]::CreateDirectory((Join-Path $legacy 'rules'))|Out-Null
    $rule=New-Rule (Copy-Probe) @{cpuPriority='AboveNormal'} 'Migrated during a planting race'
    $rule.revision=[Guid]::NewGuid().ToString('N')
    $ruleFile=Join-Path $legacy ('rules\'+$rule.ruleId+'.json')
    Write-RooIndustriesOperationJson $rule $ruleFile
    $before=(Get-FileHash -LiteralPath $ruleFile).Hash
    $script:roots.Add($legacy)
    $call=Invoke-HostLater 'policy-secure' @{} @{ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS='6000'}
    $moved=Wait-Until {-not (Test-Path -LiteralPath $legacy)} 20 20
    Assert ($null -ne $moved) 'The migration moved the earlier folder away'
    [IO.Directory]::CreateDirectory($legacy)|Out-Null
    $out=Join-Path $script:scenarioRoot 'planted.txt'
    Start-Limited (@'
try {[IO.Directory]::CreateDirectory('ROOT\rules')|Out-Null;[IO.File]::WriteAllText('ROOT\rules\planted.json','{}');$r='planted'} catch {$r='refused: '+$_.Exception.Message}
[IO.File]::WriteAllText('OUT',$r)
'@).Replace('ROOT',$legacy).Replace('OUT',$out)|Out-Null
    $null=Wait-Until {Test-Path -LiteralPath $out} 20
    $planted=if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{'no report'}
    $result=Read-HostLater $call
    $copies=@(Get-ChildItem -LiteralPath $script:policyParent -Recurse -File -Filter 'planted.json' -ErrorAction SilentlyContinue)
    $inProtected=@($copies|Where-Object {(Get-ExposedWriters $_.Directory.Parent.FullName).Count -eq 0 -and (Get-ExposedWriters $_.Directory.FullName).Count -eq 0})
    $after=if(Test-Path -LiteralPath $ruleFile){(Get-FileHash -LiteralPath $ruleFile).Hash}else{$null}
    $again=$null
    try {$again=Core 'policy-secure'} catch {$again=$_.Exception.Message}
    Note 'migrationRacePlanted' ([ordered]@{planted=$planted;status=$result.status;error=$result.error.message;copies=@($copies|ForEach-Object {$_.FullName});protectedCopies=@($inProtected|ForEach-Object {$_.FullName});hashBefore=$before;hashAfter=$after;again=$again})
    Assert ($planted -eq 'planted') 'A process without elevation could write into the recreated folder'
    Assert ($inProtected.Count -eq 0) 'A file planted without elevation never ends up inside the protected folder'
    Assert ($after -eq $before -and (Core 'policy-summary').secured -and (Get-ExposedWriters $legacy).Count -eq 0) 'The protected rules folder holds the original rule byte for byte and stays protected'
}

function Test-ScenarioMigrationBusy {
    $legacy=$script:policyRoot
    [IO.Directory]::CreateDirectory((Join-Path $legacy 'rules'))|Out-Null
    $rule=New-Rule (Copy-Probe) @{cpuPriority='AboveNormal'} 'Migration refused while busy'
    $rule.revision=[Guid]::NewGuid().ToString('N')
    $ruleFile=Join-Path $legacy ('rules\'+$rule.ruleId+'.json')
    Write-RooIndustriesOperationJson $rule $ruleFile
    $before=(Get-FileHash -LiteralPath $ruleFile).Hash
    $script:roots.Add($legacy)
    $held=Hold-File $ruleFile 0
    $failure=$null
    try {Core 'policy-secure'|Out-Null} catch {$failure=$_.Exception.Message}
    $held.stream.Dispose()
    $folders=@(Get-ChildItem -LiteralPath $script:policyParent -Directory|ForEach-Object {$_.Name})
    Note 'migrationBusy' ([ordered]@{failure=$failure;folders=$folders})
    Assert ($null -ne $failure -and $failure -like 'Stop the Roo Industries Governor before protecting its saved rules folder.*') 'A migration that cannot move the earlier folder away says so'
    Assert ((Test-Path -LiteralPath $ruleFile) -and (Get-FileHash -LiteralPath $ruleFile).Hash -eq $before -and @($folders|Where-Object {$_ -ne 'process-rules'}).Count -eq 0) 'The earlier folder is untouched and the unfinished protected copy is removed'
    Core 'policy-secure'|Out-Null
    Assert ((Core 'policy-summary').secured -and (Get-FileHash -LiteralPath $ruleFile).Hash -eq $before) 'Once nothing holds the folder the migration completes with the rule byte for byte as before'
}

function Test-ScenarioRootLease {
    $path=Copy-Probe
    Save-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'First rule')|Out-Null
    Worker 'Sync'|Out-Null
    Worker 'Pause'|Out-Null
    $second=New-Rule (Copy-Probe 'RooIndustriesGovernorSecond.exe' 'second') @{ioPriority=1} 'Second rule'
    $call=Invoke-HostLater 'rule-save' @{rule=$second} @{ROO_INDUSTRIES_TEST_SAVE_PAUSE_MS='6000'}
    Start-Sleep -Seconds 2
    $out=Join-Path $script:scenarioRoot 'limited-move.txt'
    $moved=$script:policyParent+'-moved'
    Start-Limited (@'
try {[IO.Directory]::Move('PARENT','MOVED');$r='moved'} catch {$r='refused: '+$_.Exception.Message}
[IO.File]::WriteAllText('OUT',$r)
'@).Replace('PARENT',$script:policyParent).Replace('MOVED',$moved).Replace('OUT',$out)|Out-Null
    $null=Wait-Until {Test-Path -LiteralPath $out} 20
    $attempt=if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{'no report'}
    $result=Read-HostLater $call
    if(Test-Path -LiteralPath $moved){
        if(Test-Path -LiteralPath $script:policyParent){Remove-Item -LiteralPath $script:policyParent -Recurse -Force}
        [IO.Directory]::Move($moved,$script:policyParent)
    }
    Note 'rootLease' ([ordered]@{attempt=$attempt;save=$result.status;error=$result.error.message})
    Assert ($attempt -like 'refused*') 'While a rule is being saved, a process without elevation cannot move the rules folder away'
    Assert ($result.status -eq 'completed' -and (Test-Path -LiteralPath (Join-Path $script:policyRoot ('rules\'+$second.ruleId+'.json')))) 'The rule is saved into the protected folder'
}

function Test-ScenarioGateRace {
    $context=New-GameContext
    $session=New-GameSession $context
    [IO.Directory]::CreateDirectory($session.root)|Out-Null
    [IO.File]::WriteAllText((Join-Path $session.root 'gate-pause.request'),'6000')
    $start=Start-GameSession $session -Later
    $inside=Wait-Until {Test-Path -LiteralPath (Join-Path $session.root 'gate-paused')} 60 50
    Assert ($null -ne $inside) 'The game session is starting and has checked the rules'
    $refusal=$null
    try {Save-Rule (New-Rule $context.game @{gpuPriority=1} 'Racing rule')|Out-Null} catch {$refusal=$_.Exception.Message}
    $start.WaitForExit(90000)|Out-Null
    $sessionState=if(Test-Path -LiteralPath (Join-Path $session.root 'session.json')){(Read-RooIndustriesOperationJson (Join-Path $session.root 'session.json')).data.status}else{$null}
    $rules=@(Core 'rules-list'|Where-Object {$_.name -eq 'Racing rule'})
    Note 'gateRace' ([ordered]@{refusal=$refusal;session=$sessionState;savedRules=$rules.Count})
    Assert (-not ($sessionState -and $sessionState -notin @('stopped','stoppedWithErrors') -and $rules.Count -gt 0)) 'A rule save racing a game session start never leaves both controlling the same field'
    Assert ($refusal -like 'A game session for RooIndustriesGovernorGame.exe already controls gpuPriority*') 'The rule save waits for the starting session and is refused with a clear message'
}

function Test-ScenarioLaunchFieldsByName {
    $ruleProbe=Copy-Probe 'RooIndustriesGovernorGame.exe' 'installed'
    Save-Rule (New-Rule $ruleProbe @{cpuPriority='AboveNormal'} 'Path rule')|Out-Null
    $context=New-GameContext 'other copy' '{"cpuPriority":"High"}'
    $refused=$null
    try {New-GameSession $context|Out-Null} catch {$refused=$_.Exception.Message}
    Note 'sessionForSameFileName' $refused
    Assert ($refused -like '*Managed by the governor: cpuPriority*') 'A game session cannot set launch CPU priority for a file name a path rule already controls'
    Core 'rule-delete' @{ruleId=(@(Core 'rules-list')[0]).ruleId}|Out-Null
    $session=New-GameSession $context
    Start-GameSession $session|Out-Null
    $saveRefused=$null
    try {Save-Rule (New-Rule $ruleProbe @{cpuPriority='AboveNormal'} 'Path rule again')|Out-Null} catch {$saveRefused=$_.Exception.Message}
    Note 'ruleWhileSessionForSameFileName' $saveRefused
    Assert ($saveRefused -like 'A game session for RooIndustriesGovernorGame.exe already controls cpuPriority*') 'A path rule is refused while a game session sets launch CPU priority for the same file name elsewhere'
}

function Test-ScenarioUnreadableSession {
    $broken=Join-Path $script:policyParent ('operations\game-session-'+[Guid]::NewGuid().ToString('N')+'\session')
    [IO.Directory]::CreateDirectory($broken)|Out-Null
    [IO.File]::WriteAllText((Join-Path $broken 'session.json'),'not json',[Text.UTF8Encoding]::new($false))
    $saved=$null;$error1=$null
    try {$saved=Save-Rule (New-Rule (Copy-Probe) @{cpuPriority='AboveNormal'} 'Unrelated rule')} catch {$error1=$_.Exception.Message}
    $log=Join-Path $script:policyRoot 'logs\governor.log'
    Note 'unrelated' ([ordered]@{error=$error1;log=$(if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{$null})})
    Assert ($null -ne $saved -and $null -eq $error1) 'A broken game session folder does not block an unrelated rule'
    Assert ((Test-Path -LiteralPath $log) -and ([IO.File]::ReadAllText($log) -like ('*'+(Split-Path (Split-Path $broken -Parent) -Leaf)+'*'))) 'The skipped folder is logged'
    $context=New-GameContext
    $session=New-GameSession $context
    [IO.Directory]::CreateDirectory($session.root)|Out-Null
    Copy-Item -LiteralPath $session.file -Destination (Join-Path $session.root 'reviewed-preview.json')
    [IO.File]::WriteAllText((Join-Path $session.root 'session.json'),'not json',[Text.UTF8Encoding]::new($false))
    $error2=$null
    try {Save-Rule (New-Rule $context.game @{gpuPriority=1} 'Game rule')|Out-Null} catch {$error2=$_.Exception.Message}
    Note 'matching' $error2
    Assert ($error2 -like 'A game session for RooIndustriesGovernorGame.exe could not be read*') 'A broken session for the same game and field still blocks the rule'
    Remove-Item -LiteralPath (Join-Path $session.root 'session.json') -Force
}

function Test-ScenarioApplyOnceRace {
    $path=Copy-Probe
    $probe=Start-Probe $path
    $operation=Join-Path $script:policyParent ('operations\process-'+[Guid]::NewGuid().ToString('N'))
    $preview=Join-Path $operation 'preview.json'
    Core 'process-preview' @{processId=$probe.Id;controls=@{cpuPriority='BelowNormal'};outputPath=$preview}|Out-Null
    $journal=Join-Path $operation 'journal.json'
    $script:cleanups.Add({try {Core 'process-restore' @{journalPath=$journal} (Join-Path $script:scenarioRoot 'unrelated-rules')|Out-Null} catch {}}.GetNewClosure())
    $call=Invoke-HostLater 'process-apply' @{previewPath=$preview;reviewHash=(Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash;journalPath=$journal} @{ROO_INDUSTRIES_TEST_APPLY_PAUSE_MS='6000'}
    Start-Sleep -Seconds 2
    $refusal=$null
    try {Save-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Racing rule')|Out-Null} catch {$refusal=$_.Exception.Message}
    $applied=Read-HostLater $call
    $rules=@(Core 'rules-list'|Where-Object {$_.enabled})
    Note 'applyOnceRace' ([ordered]@{refusal=$refusal;apply=$applied.status;applyError=$applied.error.message;rules=$rules.Count})
    Assert (-not ($applied.status -eq 'completed' -and $rules.Count -gt 0)) 'A rule save racing Apply once never leaves both owning the same field'
    Assert ($refusal -like 'Undo the Apply once change on RooIndustriesGovernorProbe.exe*') 'The rule save waits for Apply once and is refused with a clear message'
}

function Test-ScenarioGovernorLog {
    $path=Copy-Probe 'RooIndustriesGovernorLogA.exe'
    $first=Start-Probe $path
    Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'First log entry' 'filename')|Out-Null
    Assert ($null -ne (Wait-Until {[string](Read-Field $first 'cpuPriority') -eq 'AboveNormal'} 10)) 'The rule is applied'
    $log=Join-Path $script:policyRoot 'logs\governor.log'
    $beside=Join-Path $script:policyParent 'logs\governor.log'
    $hold=[IO.FileStream]::new((Join-Path $script:policyRoot 'host.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {$second=Start-Probe $path;$null=Wait-Until {Test-Path -LiteralPath $log} 8 100} finally {$hold.Dispose()}
    Note 'locations' ([ordered]@{insideRulesFolder=(Test-Path -LiteralPath $log);besideRulesFolder=(Test-Path -LiteralPath $beside)})
    Assert ((Test-Path -LiteralPath $log) -and -not (Test-Path -LiteralPath $beside)) 'The governor log is written inside the protected rules folder, not beside it'
    $text=[IO.File]::ReadAllText($log)
    Note 'firstEntry' ($text -split "`n"|Select-Object -First 1)
    Assert ($text -like '*A governor check failed and will be retried*') 'A failed governor check is written to the log'
    $exposed=New-Object System.Collections.Generic.List[string]
    foreach($item in @((Split-Path $log -Parent),$log)){foreach($line in @(Get-ExposedWriters $item)){$exposed.Add($line)}}
    Note 'writableByOthers' @($exposed)
    Assert ($exposed.Count -eq 0) 'Only administrators and SYSTEM can write, delete or re-permission the log and its folder'
    $out=Join-Path $script:scenarioRoot 'limited-log.txt'
    Start-Limited (@'
$r=@()
try {[IO.File]::AppendAllText('LOG','x');$r+='appended'} catch {$r+='refused'}
try {[IO.File]::WriteAllText('NEW','x');$r+='created'} catch {$r+='refused'}
try {Remove-Item -LiteralPath 'LOG' -Force -ErrorAction Stop;$r+='deleted'} catch {$r+='refused'}
[IO.File]::WriteAllText('OUT',($r -join ','))
'@).Replace('LOG',$log).Replace('NEW',(Join-Path (Split-Path $log -Parent) 'planted.log')).Replace('OUT',$out)|Out-Null
    $null=Wait-Until {Test-Path -LiteralPath $out} 20
    $attempt=if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{'no report'}
    Note 'standardTokenWrites' $attempt
    Assert ($attempt -eq 'refused,refused,refused') 'A process without elevation cannot append to, add beside or delete the log'
    $broken=Join-Path $script:policyParent ('operations\game-session-'+[Guid]::NewGuid().ToString('N')+'\session')
    [IO.Directory]::CreateDirectory($broken)|Out-Null
    [IO.File]::WriteAllText((Join-Path $broken 'session.json'),'not json',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($log,('x'*99+"`n")*3000)
    $seeded=(Get-Item -LiteralPath $log).Length
    Save-Rule (New-Rule (Copy-Probe 'RooIndustriesGovernorLogB.exe') @{cpuPriority='AboveNormal'} 'Second log entry')|Out-Null
    $rotated=$log+'.1'
    Note 'rotation' ([ordered]@{seeded=$seeded;rotatedLength=$(if(Test-Path -LiteralPath $rotated){(Get-Item -LiteralPath $rotated).Length});liveLength=(Get-Item -LiteralPath $log).Length})
    Assert ((Test-Path -LiteralPath $rotated) -and (Get-Item -LiteralPath $rotated).Length -ge $seeded -and (Get-Item -LiteralPath $log).Length -lt 4096) 'A log over 256 KB is moved aside and a fresh one started, so the log stays capped'
    Assert (([IO.File]::ReadAllText($log)) -like '*Skipped a game session*') 'The fresh log holds the new entry'
}
