param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference = 'Stop'
if (-not $IsLinux) { throw 'This dependency simulation requires Linux.' }
$Source = [IO.Path]::GetFullPath($Source)
$OutRoot = [IO.Path]::GetFullPath($OutRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot) | Out-Null
$failures = New-Object System.Collections.Generic.List[object]
$cases = New-Object System.Collections.Generic.List[object]
$probes = New-Object System.Collections.Generic.List[object]
function Save([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 40),$utf8) }
function Read-Ast([string]$Path) {
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Source $Path),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    return $ast
}
function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) { $failures.Add([pscustomobject]@{scenario=$name;assertion=$Message}) | Out-Null; "FAIL $name $Message" }
}
function Rows($Object,[string]$Property) {
    Get-RooIndustriesPropertyArray $Object $Property | Where-Object { $null -ne $_ -and $_ -is [pscustomobject] }
}
$paths = @('backend/scripts/OperationState.Common.ps1','backend/scripts/GovernorOwnership.Common.ps1','backend/scripts/ProcessProfile.Common.ps1','backend/scripts/Restore-ProcessProfileBackup.ps1')
$asts = @{}
$sourceHashes = foreach ($path in $paths) {
    $asts[$path] = Read-Ast $path
    [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath (Join-Path $Source $path) -Algorithm SHA256).Hash}
}
Save (Join-Path $OutRoot 'source-hashes.json') @($sourceHashes)
function Invoke-Scenario([string]$Stage,[string]$Initial,[bool]$WithPeer,[bool]$Ended=$false) {
    $name = $Stage+'-'+$Initial+'-'+$(if($WithPeer){'peer'}else{'single'})+$(if($Ended){'-ended'}else{''})
    $directory = Join-Path $OutRoot $name
    $runtime = Join-Path $directory 'runtime'
    [IO.Directory]::CreateDirectory((Join-Path $runtime 'operations')) | Out-Null
    $peer = $null; $target = $null; $ledger = $null
    $beforeFailures = $failures.Count
    try {
        $target = [Diagnostics.Process]::GetCurrentProcess()
        if ($WithPeer) {
            $peer = [Diagnostics.Process]::Start('/bin/sleep','600')
            $ledger = [pscustomobject]@{scenario=$name;processId=$peer.Id;creationTimeFileTimeUtc=$peer.StartTime.ToUniversalTime().ToFileTimeUtc();exited=$false;disposed=$false}
            $probes.Add($ledger) | Out-Null
            Save (Join-Path $OutRoot 'owned-probes.json') @($probes.ToArray())
            if ($peer.Id -eq $target.Id) { throw 'The peer must be a distinct live process instance.' }
        }
        & {
            foreach ($path in $paths) {
                foreach ($statement in $asts[$path].EndBlock.Statements) {
                    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst] -or ($path -like '*Common.ps1' -and $statement -is [Management.Automation.Language.AssignmentStatementAst])) {
                        . ([scriptblock]::Create($statement.Extent.Text))
                    }
                }
            }
            $script:IdentityProcesses = @{}; $script:IdentityValues = @{}
            $script:IdentityProcesses[[string]$target.Id] = $target
            $script:IdentityValues[[string]$target.Id] = $Initial
            if ($WithPeer) { $script:IdentityProcesses[[string]$peer.Id] = $peer; $script:IdentityValues[[string]$peer.Id] = 'BelowNormal' }
            $snapshots = foreach ($process in @($target,$peer) | Where-Object { $null -ne $_ }) {
                [pscustomobject]@{processId=$process.Id;processName=$(if($process.Id -eq $target.Id){'IdentityTarget'}else{'IdentityPeer'});processStartTimeUtc=$process.StartTime.ToUniversalTime().ToString('o');originalPriorityClass='Normal';proposedPriorityClass='BelowNormal';controlChanges=@([pscustomobject]@{control='priorityClass';proposedValue='BelowNormal';outcome='applied'})}
            }
            $backupFile = Join-Path $directory 'backup.json'
            Save $backupFile ([pscustomobject]@{actionId='performance.applyProfile';dryRun=$false;backupId='identity-recovery';profileId='identity-fixture';createdAtUtc='2026-10-01T00:00:00Z';snapshots=@($snapshots)})
            $backupHash = (Get-FileHash -LiteralPath $backupFile).Hash
            $script:IdentityRetry = $false
            function Get-RooIndustriesLocalDataRoot { return $runtime }
            function Test-RooIndustriesGovernorOwnsControl { param($Process,$Control) return $false }
            function Reset-Metrics {
                $script:IdentityCalls = @{}; $script:IdentityReads = @{}; $script:IdentityGates = @{}
                foreach ($key in $script:IdentityProcesses.Keys) { $script:IdentityCalls[$key]=0; $script:IdentityReads[$key]=0; $script:IdentityGates[$key]=0 }
                $script:IdentityInjectionHits=0; $script:IdentityRebuildHits=0; $script:IdentityAcquired=0; $script:IdentityReleased=0; $script:IdentityOutsideReads=0; $script:IdentityHeld=$false; $script:IdentityCurrentId=0
                $script:IdentityWrites = New-Object System.Collections.Generic.List[object]
            }
            function Get-RestoreCandidate {
                param($Snapshot)
                $key = [string]$Snapshot.processId
                $script:IdentityCurrentId = [int]$Snapshot.processId
                $script:IdentityCalls[$key]++
                $call = $script:IdentityCalls[$key]
                $isTarget = $Snapshot.processId -eq $target.Id
                $badCall = if($Stage -eq 'blocked-at-preview'){1}else{2}
                $bad = $isTarget -and -not $script:IdentityRetry -and $Stage -ne 'stable' -and $call -eq $badCall
                $isEnded = $isTarget -and $Ended -and -not $script:IdentityRetry -and $call -gt $badCall
                if ($bad) { $script:IdentityInjectionHits++ }
                if ($isTarget -and -not $script:IdentityRetry -and $Stage -ne 'stable' -and $call -gt $badCall) { $script:IdentityRebuildHits++ }
                $value = $script:IdentityValues[$key]
                $reason = if($isEnded){'This app was already closed or restarted. Nothing remains to restore for the saved instance.'}elseif($bad){'This app was restarted, or its start time could not be verified. Nothing was restored.'}else{$null}
                return [pscustomobject]@{exists=(-not $isEnded);matches=(-not $bad -and -not $isEnded);instanceEnded=$isEnded;process=$script:IdentityProcesses[$key];currentPriorityClass=$value;currentControlState=[pscustomobject]@{priorityClass=$value;process=$script:IdentityProcesses[$key];gpuPriorityAvailable=$false};blockedReason=$reason}
            }
            function Get-RooIndustriesProcessControlState {
                param($ProcessId,$Unused,[switch]$ReadGpu)
                return [pscustomobject]@{priorityClass=$script:IdentityValues[[string]$ProcessId];process=$script:IdentityProcesses[[string]$ProcessId]}
            }
            function Enter-RooIndustriesGovernorGate {
                param($Seconds)
                if ($script:IdentityHeld) { throw 'Unexpected nested fixture gate.' }
                $script:IdentityAcquired++; $script:IdentityHeld=$true
                $script:IdentityGates[[string]$script:IdentityCurrentId]++
                return [pscustomobject]@{fixtureGate=$true}
            }
            function Exit-RooIndustriesGovernorGate {
                param($Gate)
                if ($null -ne $Gate) { $script:IdentityReleased++; $script:IdentityHeld=$false }
            }
            function Get-RooIndustriesProcessControlReadback {
                param($Process,$Control)
                $script:IdentityReads[[string]$Process.Id]++
                if (-not $script:IdentityHeld) { $script:IdentityOutsideReads++ }
                return $script:IdentityValues[[string]$Process.Id]
            }
            function Invoke-RooIndustriesProcessControlChange {
                param($Process,$Change)
                $script:IdentityWrites.Add([pscustomobject]@{processId=$Process.Id;control=$Change.control;value=$Change.proposedValue}) | Out-Null
                $script:IdentityValues[[string]$Process.Id] = [string]$Change.proposedValue
                $Change.outcome = 'applied'
            }
            function Invoke-Undo([string]$Phase) {
                $ConfirmApply=$true; $BackupPath=$backupFile; $OutputPath=Join-Path $directory ($Phase+'.json')
                $body = $asts['backend/scripts/Restore-ProcessProfileBackup.ps1'].EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
                return (& ([scriptblock]::Create($body.Extent.Text)) | ConvertFrom-Json)
            }
            function Observe([string]$Phase) {
                $perProcess = foreach ($key in $script:IdentityProcesses.Keys) {
                    [pscustomobject]@{processId=[int]$key;value=$script:IdentityValues[$key];identityCalls=$script:IdentityCalls[$key];directReads=$script:IdentityReads[$key];gates=$script:IdentityGates[$key];writes=@($script:IdentityWrites | Where-Object processId -eq ([int]$key))}
                }
                $observation = [pscustomobject]@{phase=$Phase;targetId=$target.Id;peerId=$(if($WithPeer){$peer.Id}else{$null});processes=@($perProcess);injectionHits=$script:IdentityInjectionHits;rebuildHits=$script:IdentityRebuildHits;acquired=$script:IdentityAcquired;released=$script:IdentityReleased;held=$script:IdentityHeld;readbackOutsideGate=$script:IdentityOutsideReads;backupUnchanged=((Get-FileHash -LiteralPath $backupFile).Hash -eq $backupHash)}
                Save (Join-Path $directory ($Phase+'-observation.json')) $observation
                Check ($observation.acquired -eq $observation.released -and -not $observation.held -and $observation.readbackOutsideGate -eq 0) "$Phase balanced gates and no ungated direct readback"
                Check $observation.backupUnchanged "$Phase retained the same backup"
                return $observation
            }
            function Check-Completed($Envelope,[string]$Phase,[int]$ExpectedPeerWrites) {
                $left = @(Rows $Envelope.result 'leftAsSetItems')
                $targetLeft = @($left | Where-Object processId -eq $target.Id)
                $targetWrites = @($script:IdentityWrites | Where-Object processId -eq $target.Id)
                Check ($Envelope.status -eq 'success' -and $Envelope.result.status -eq 'success' -and $Envelope.result.restorePendingCount -eq 0 -and @(Rows $Envelope.result 'pendingItems').Count -eq 0) "$Phase completed recovery"
                Check (@(Rows $Envelope.result 'skippedItems').Count -eq 0) "$Phase has no skipped controls"
                if ($Initial -eq 'High') {
                    Check ($script:IdentityValues[[string]$target.Id] -eq 'High' -and $targetWrites.Count -eq 0 -and $left.Count -eq 1 -and $targetLeft.Count -eq 1 -and $targetLeft[0].control -eq 'priorityClass' -and $targetLeft[0].currentValue -eq 'High' -and $targetLeft[0].processName -eq 'IdentityTarget' -and $Envelope.result.summary.Contains('IdentityTarget CPU priority (High)')) "$Phase kept and named exactly the external target control"
                } elseif ($Initial -eq 'Normal') {
                    Check ($script:IdentityValues[[string]$target.Id] -eq 'Normal' -and $targetWrites.Count -eq 0 -and $left.Count -eq 0) "$Phase verified the original without a write or external attribution"
                } else {
                    Check ($script:IdentityValues[[string]$target.Id] -eq 'Normal' -and $targetWrites.Count -eq 1 -and $targetWrites[0].control -eq 'priorityClass' -and $targetWrites[0].value -eq 'Normal' -and $left.Count -eq 0) "$Phase restored the applied target exactly once"
                }
                if ($Initial -in @('High','Normal')) { Check ($script:IdentityGates[[string]$target.Id] -eq 1 -and $script:IdentityReads[[string]$target.Id] -eq 1) "$Phase freshly confirmed the target under one gate" }
                if ($WithPeer) { Check ($script:IdentityValues[[string]$peer.Id] -eq 'Normal' -and @($script:IdentityWrites | Where-Object processId -eq $peer.Id).Count -eq $ExpectedPeerWrites) "$Phase peer has the expected independent writes" }
            }
            Reset-Metrics
            $first = Invoke-Undo 'first'
            $firstObservation = Observe 'first'
            if ($Stage -eq 'stable') {
                Check-Completed $first 'first' 0
            } else {
                $expectedCalls = if($Stage -eq 'blocked-at-preview'){2}else{3}
                Check ($script:IdentityInjectionHits -eq 1 -and $script:IdentityRebuildHits -eq 1 -and $script:IdentityCalls[[string]$target.Id] -eq $expectedCalls) 'first reached the transient and subsequent rebuild'
                $skipped = @(Rows $first.result 'skippedItems' | Where-Object processId -eq $target.Id)
                $category = if($Stage -eq 'blocked-at-preview'){'blocked'}else{'exited'}
                Check ($skipped.Count -eq 1 -and $skipped[0].category -eq $category -and -not [string]::IsNullOrWhiteSpace($skipped[0].reason)) 'first reports the exact identity-skip category and reason'
                Check ($script:IdentityValues[[string]$target.Id] -eq $Initial -and @($script:IdentityWrites | Where-Object processId -eq $target.Id).Count -eq 0 -and $script:IdentityReads[[string]$target.Id] -eq 0 -and $script:IdentityGates[[string]$target.Id] -eq 0 -and @(Rows $first.result 'leftAsSetItems').Count -eq 0 -and -not $first.result.summary.Contains('IdentityTarget CPU priority')) 'first never wrote, read back, gated or certified the skipped target'
                if ($Ended) {
                    $closed = @(Rows $first.result 'alreadyClosedItems')
                    Check ($first.status -eq 'success' -and $first.result.status -eq 'success' -and $first.result.restorePendingCount -eq 0 -and @(Rows $first.result 'pendingItems').Count -eq 0 -and $closed.Count -eq 1 -and $closed[0].processId -eq $target.Id -and $first.result.summary.Contains('Already closed or restarted: IdentityTarget (PID '+$target.Id+')')) 'first closes the ended saved instance before retaining skip categories'
                } else {
                    $expectedStatus = if($WithPeer){'partial'}else{'failed'}
                    $pending = @(Rows $first.result 'pendingItems')
                    $changed = @(Rows $first.result 'changedItems')
                    Check ($first.status -eq $expectedStatus -and $first.result.status -eq $expectedStatus -and $first.result.restorePendingCount -eq 1 -and $pending.Count -eq 1 -and $pending[0].processId -eq $target.Id -and @(Rows $first.result 'alreadyClosedItems').Count -eq 0) 'first retains exactly the unverified target recovery'
                    if ($WithPeer) {
                        Check ($changed.Count -eq 1 -and $changed[0].processId -eq $peer.Id -and $script:IdentityValues[[string]$peer.Id] -eq 'Normal' -and @($script:IdentityWrites | Where-Object processId -eq $peer.Id).Count -eq 1) 'first restores only the independent peer exactly once'
                    } else { Check ($changed.Count -eq 0) 'first records no restored app' }
                    $script:IdentityRetry = $true
                    Reset-Metrics
                    $retry = Invoke-Undo 'retry'
                    $null = Observe 'retry'
                    Check-Completed $retry 'retry' 0
                    Check ($script:IdentityInjectionHits -eq 0) 'retry used a fresh explicit invocation without the transient'
                }
            }
            $cases.Add([pscustomobject]@{scenario=$name;stage=$Stage;initial=$Initial;withPeer=$WithPeer;ended=$Ended;firstStatus=$first.status;firstPending=$first.result.restorePendingCount;first=$firstObservation;failures=($failures.Count-$beforeFailures)}) | Out-Null
        }
    } catch {
        $failures.Add([pscustomobject]@{scenario=$name;assertion=$_.ToString();stack=$_.ScriptStackTrace}) | Out-Null
        "FAIL $name setup/body: $_"
    } finally {
        if ($null -ne $peer) {
            try { if (-not $peer.HasExited) { $peer.Kill() }; $peer.WaitForExit(); $ledger.exited=$peer.HasExited }
            finally { $peer.Dispose(); $ledger.disposed=$true; Save (Join-Path $OutRoot 'owned-probes.json') @($probes.ToArray()) }
        }
        if ($null -ne $target) { $target.Dispose() }
        if ([IO.Directory]::Exists($runtime)) { [IO.Directory]::Delete($runtime,$true) }
    }
    "CASE $name failures=$($failures.Count-$beforeFailures)"
}
foreach ($stage in 'blocked-at-preview','exited-at-confirm') {
    foreach ($initial in 'High','Normal','BelowNormal') { Invoke-Scenario $stage $initial $false; Invoke-Scenario $stage $initial $true }
}
foreach ($initial in 'High','Normal','BelowNormal') { Invoke-Scenario 'stable' $initial $false }
foreach ($stage in 'blocked-at-preview','exited-at-confirm') { Invoke-Scenario $stage 'High' $false $true }
if ($cases.Count -ne 17) { $failures.Add([pscustomobject]@{scenario='harness';assertion='Expected all 17 complete cases.'}) | Out-Null }
Save (Join-Path $OutRoot 'summary.json') ([pscustomobject]@{proof='Linux dependency simulation: real production AST functions/main body, JSON backup/output persistence and native ownership reader over an empty fixture data root; identity, process-control I/O and gates simulated. No Windows or native process-control proof.';source=$Source;caseCount=$cases.Count;failedCases=@($failures | Select-Object -ExpandProperty scenario -Unique).Count;failureCount=$failures.Count;cases=@($cases.ToArray());failures=@($failures.ToArray());ownedProbes=@($probes.ToArray());runtimeFixturesRemaining=@(Get-ChildItem -LiteralPath $OutRoot -Filter runtime -Directory -Recurse).Count})
"Identity recovery: $($cases.Count) cases, $($failures.Count) failures"
if ($failures.Count) { exit 1 }
