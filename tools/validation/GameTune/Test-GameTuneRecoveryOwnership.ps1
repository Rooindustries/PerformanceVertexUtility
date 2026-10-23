param(
    [string]$Source = (Join-Path $PSScriptRoot '../../..'),
    [Parameter(Mandatory = $true)][string]$Out,
    [ValidateSet('All', 'RecoveryRace', 'ManualRace', 'Controls', 'LegacySelection')][string]$Scenario = 'All'
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[object]
$checks = New-Object System.Collections.Generic.List[object]
$engine = Join-Path $Out 'engine'
New-Item -ItemType Directory -Path $engine -Force | Out-Null
foreach ($name in @('GameTuneSession.Common.ps1', 'ProcessProfile.Common.ps1', 'GovernorOwnership.Common.ps1', 'BrandCompatibility.Common.ps1', 'OperationState.Common.ps1', 'Stop-GameTuneSession.ps1', 'Get-GameTuneSessionStatus.ps1')) {
    Copy-Item -LiteralPath (Join-Path $Source "backend/scripts/$name") -Destination (Join-Path $engine $name)
}
@'
function Enter-RooIndustriesGovernorGate { return $true }
function Exit-RooIndustriesGovernorGate { param($Gate) }
function Test-RooIndustriesGovernorOwnsControl { param($Process, $Control) return $false }
function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    if ($null -ne $global:RooIndustriesTuneFixture -and $null -ne $global:RooIndustriesTuneFixture.liveController -and $Id -eq $PID) { return $global:RooIndustriesTuneFixture.liveController }
    return Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction SilentlyContinue
}
function Get-RooIndustriesGameTuneLiveProcessIdentity {
    param($Entry)
    $global:RooIndustriesTuneFixture.identityReads++
    if ($global:RooIndustriesTuneFixture.identityReads -eq $global:RooIndustriesTuneFixture.injectIdentity) {
        $global:RooIndustriesTuneFixture.state.($global:RooIndustriesTuneFixture.control) = $global:RooIndustriesTuneFixture.foreign
    }
    $state = $global:RooIndustriesTuneFixture.state
    return [pscustomobject]@{ exists = $true; matches = $true; instanceEnded = $false; process = (Get-Process -Id $PID); currentPriorityClass = $state.priorityClass; currentAffinityMask = $state.affinityMask; currentIoPriority = $state.ioPriority; currentMemoryPriority = $state.memoryPriority; currentGpuPriority = $state.gpuPriority; currentControlState = $state; reason = $null }
}
function Get-RooIndustriesProcessControlState {
    param($ProcessId, $Unused, [switch]$ReadGpu)
    return $global:RooIndustriesTuneFixture.state
}
function Get-RooIndustriesProcessControlReadback {
    param($Process, $Control)
    $global:RooIndustriesTuneFixture.readbacks++
    if ($global:RooIndustriesTuneFixture.readbacks -eq $global:RooIndustriesTuneFixture.injectReadback) {
        $global:RooIndustriesTuneFixture.state.($global:RooIndustriesTuneFixture.control) = $global:RooIndustriesTuneFixture.foreign
    }
    return $global:RooIndustriesTuneFixture.state.$Control
}
function Invoke-RooIndustriesProcessControlChange {
    param($Process, $Change)
    $current = Get-RooIndustriesProcessControlReadback $Process $Change.control
    if (-not (Test-RooIndustriesControlValueEqual $Change.control $current $Change.currentValue)) {
        throw 'The control changed externally; its current value was preserved.'
    }
    $global:RooIndustriesTuneFixture.writes.Add([pscustomobject]@{ control = $Change.control; expected = $Change.currentValue; value = $Change.proposedValue }) | Out-Null
    $global:RooIndustriesTuneFixture.state.($Change.control) = $Change.proposedValue
    $Change.outcome = 'applied'
}
'@ | Add-Content -LiteralPath (Join-Path $engine 'GameTuneSession.Common.ps1')
. (Join-Path $engine 'GameTuneSession.Common.ps1')

function Check([bool]$Condition, [string]$Message) {
    $checks.Add([pscustomobject]@{ passed = $Condition; message = $Message }) | Out-Null
    Write-Host "$(if ($Condition) { 'PASS' } else { 'FAIL' }) $Message"
}

function Invoke-RestoreCase {
    param([string]$Name, [string]$Mode, [object[]]$Controls, [string]$Conflict = '', [int]$InjectIdentity = 0, [int]$InjectReadback = 0, [switch]$Original, [string]$Outcome = 'applied', [switch]$MissingApplied, [switch]$MissingOriginal)
    $directory = Join-Path $Out $Name
    $sessionPath = Join-Path $directory 'session.json'
    $backupPath = Join-Path $directory 'backup.json'
    $state = [pscustomobject]@{ priorityClass = 'Normal'; affinityMask = 15; ioPriority = 'Normal'; memoryPriority = 5; gpuPriority = 'Normal'; gpuPriorityAvailable = $true; memoryPriorityAvailable = $true }
    $snapshot = [pscustomobject]@{ processId = $PID; processName = 'FixtureGame.exe'; executablePath = 'C:\Games\FixtureGame.exe'; processStartTimeUtc = '2026-10-23T00:00:00Z'; controlChanges = @() }
    foreach ($control in $Controls) {
        $state.($control.name) = if ($Original) { $control.original } else { $control.applied }
        $snapshot | Add-Member -NotePropertyName $control.field -NotePropertyValue $(if ($MissingOriginal) { $null } else { $control.original })
        $snapshot.controlChanges += [pscustomobject]@{ control = $control.name; currentValue = $control.original; proposedValue = if ($MissingApplied) { $null } else { $control.applied }; action = 'set'; outcome = $Outcome }
    }
    $foreign = if ($Conflict) { ($Controls | Where-Object name -eq $Conflict).foreign } else { $null }
    $global:RooIndustriesTuneFixture = @{ state = $state; control = $Conflict; foreign = $foreign; identityReads = 0; readbacks = 0; injectIdentity = $InjectIdentity; injectReadback = $InjectReadback; writes = (New-Object System.Collections.Generic.List[object]) }
    $session = [pscustomobject]@{ sessionId = $Name; profileId = 'fixture-profile'; sessionStatus = 'completed'; status = 'completed'; startedAtUtc = '2026-10-23T00:00:00Z'; ownerProcessId = $PID; ownerStartTimeUtc = '2001-01-01T00:00:00Z'; workerProcessId = $PID; workerStartTimeUtc = '2001-01-01T00:00:00Z'; recoverWhenOwnerEnds = $true; completedAtUtc = $null; backupManifestPath = $backupPath; sessionPath = $sessionPath; restorable = $true; restoredItems = @(); skippedItems = @(); logs = @(); errors = @() }
    $backup = [pscustomobject]@{ actionId = 'performance.gameTune.startSession'; dryRun = $false; backupId = 'fixture-backup'; createdAtUtc = '2026-10-23T00:00:00Z'; sessionId = $Name; profileId = 'fixture-profile'; snapshots = @($snapshot) }
    Write-RooIndustriesGameTuneJsonFile $session $sessionPath
    Write-RooIndustriesGameTuneJsonFile $backup $backupPath
    $backupHash = (Get-FileHash -LiteralPath $backupPath).Hash
    if ($Mode -eq 'Recovery') {
        $result = Repair-RooIndustriesInterruptedGameTuneSession (Read-RooIndustriesJsonFile $sessionPath) $sessionPath
    } elseif ($Mode -eq 'Preview') {
        $result = & (Join-Path $engine 'Stop-GameTuneSession.ps1') -SessionPath $sessionPath | ConvertFrom-Json
    } else {
        $result = & (Join-Path $engine 'Stop-GameTuneSession.ps1') -SessionPath $sessionPath -ConfirmApply | ConvertFrom-Json
    }
    $saved = Read-RooIndustriesJsonFile $sessionPath
    $writes = @($global:RooIndustriesTuneFixture.writes.ToArray())
    $results.Add([pscustomobject]@{ name = $Name; state = $state; writes = $writes; result = $result; saved = $saved }) | Out-Null
    if ($Conflict) {
        Check ((Test-RooIndustriesControlValueEqual $Conflict $state.$Conflict $foreign) -and @($writes | Where-Object control -eq $Conflict).Count -eq 0) "$Name preserves the foreign $Conflict without a write"
        Check ($saved.restorable -and $saved.sessionStatus -ne 'completed' -and ($saved.skippedItems | ConvertTo-Json -Depth 10) -match 'Left as another program set it') "$Name reports the control left as another program set it and retains recovery"
        if ($Mode -eq 'Recovery') {
            $before = [IO.File]::ReadAllText($sessionPath)
            $again = Repair-RooIndustriesInterruptedGameTuneSession $saved $sessionPath
            Check ($again.sessionStatus -eq 'failed' -and [IO.File]::ReadAllText($sessionPath) -ceq $before -and @($again.errors | Where-Object code -eq 'GAME_TUNE_RECOVERY_NEEDS_ATTENTION').Count -eq 1) "$Name does not automatically retry the conflict"
        } elseif ($Controls.Count -gt 1) {
            $again = & (Join-Path $engine 'Stop-GameTuneSession.ps1') -SessionPath $sessionPath -ConfirmApply | ConvertFrom-Json
            Check ($again.restorable -and $again.sessionStatus -ne 'completed' -and (Test-RooIndustriesControlValueEqual $Conflict $state.$Conflict $foreign) -and $global:RooIndustriesTuneFixture.writes.Count -eq $writes.Count) "$Name keeps the conflict on repeated Stop without rewriting restored controls"
        }
    } elseif ($Mode -eq 'Preview' -or $Original) {
        Check ($writes.Count -eq 0) "$Name writes no controls"
        if ($Mode -eq 'Preview') { Check ($saved.sessionStatus -eq 'completed' -and $saved.restorable -and $result.dryRun) "$Name preserves the session during preview" }
        else { Check (-not $saved.restorable) "$Name needs no further restore" }
    } elseif ($MissingApplied -or $MissingOriginal) {
        Check ($writes.Count -eq 0 -and $saved.restorable -and $saved.sessionStatus -ne 'completed') "$Name keeps values and evidence when saved control evidence is missing"
    }
    foreach ($control in $Controls) {
        if ($Mode -eq 'Preview' -or $MissingApplied -or $MissingOriginal -or $control.name -eq $Conflict) { continue }
        Check ((Test-RooIndustriesControlValueEqual $control.name $state.($control.name) $control.original) -and @($writes | Where-Object { $_.control -eq $control.name -and -not (Test-RooIndustriesControlValueEqual $control.name $_.expected $control.applied) }).Count -eq 0) "$Name restores $($control.name) only from its saved applied value"
    }
    Check ((Test-Path -LiteralPath $backupPath) -and (Get-FileHash -LiteralPath $backupPath).Hash -ceq $backupHash) "$Name keeps the original backup intact"
}

try {
    $controls = @(
        @{ name = 'priorityClass'; field = 'originalPriorityClass'; original = 'Normal'; applied = 'AboveNormal'; foreign = 'High' },
        @{ name = 'affinityMask'; field = 'originalAffinityMask'; original = 15; applied = 7; foreign = 3 },
        @{ name = 'ioPriority'; field = 'originalIoPriority'; original = 'Normal'; applied = 'Low'; foreign = 'VeryLow' },
        @{ name = 'memoryPriority'; field = 'originalMemoryPriority'; original = 5; applied = 3; foreign = 1 },
        @{ name = 'gpuPriority'; field = 'originalGpuPriority'; original = 'Normal'; applied = 'AboveNormal'; foreign = 'High' }
    )
    if ($Scenario -in 'All', 'RecoveryRace') { Invoke-RestoreCase 'recovery-preflight-race' 'Recovery' @($controls[0]) -Conflict priorityClass -InjectIdentity 2 }
    if ($Scenario -in 'All', 'ManualRace') {
        Invoke-RestoreCase 'manual-preview-race' 'Manual' @($controls[0]) -Conflict priorityClass -InjectIdentity 1
        Invoke-RestoreCase 'manual-setter-race' 'Manual' @($controls[0]) -Conflict priorityClass -InjectReadback 1
        Invoke-RestoreCase 'manual-final-read-race' 'Manual' @($controls[0]) -Conflict priorityClass -InjectReadback 2
        Invoke-RestoreCase 'manual-original-race' 'Manual' @($controls[0]) -Conflict priorityClass -InjectReadback 1 -Original
    }
    if ($Scenario -in 'All', 'Controls') {
        foreach ($control in $controls) {
            Invoke-RestoreCase ($control.name + '-foreign') 'Manual' @($control) -Conflict $control.name -InjectIdentity 1
            Invoke-RestoreCase ($control.name + '-pending-foreign') 'Manual' @($control) -Conflict $control.name -InjectIdentity 1 -Outcome pending
        }
        Invoke-RestoreCase 'owned-controls' 'Manual' $controls
        Invoke-RestoreCase 'already-original' 'Manual' $controls -Original
        Invoke-RestoreCase 'pending-applied' 'Manual' $controls -Outcome pending
        Invoke-RestoreCase 'pending-original' 'Manual' $controls -Outcome pending -Original
        Invoke-RestoreCase 'failed-before-write' 'Manual' $controls -Outcome failed -Original
        Invoke-RestoreCase 'failed-after-write' 'Manual' $controls -Outcome failed
        Invoke-RestoreCase 'failed-write-foreign' 'Manual' $controls -Outcome failed -Conflict priorityClass -InjectIdentity 1
        Invoke-RestoreCase 'missing-applied' 'Manual' $controls -MissingApplied
        Invoke-RestoreCase 'missing-original' 'Manual' $controls -MissingOriginal
        Invoke-RestoreCase 'mixed-controls' 'Manual' $controls -Conflict ioPriority -InjectIdentity 1
        Invoke-RestoreCase 'preview-only' 'Preview' $controls
    }
    if ($Scenario -in 'All', 'LegacySelection') {
        $stateRoot = Join-Path $Out 'legacy-state'
        $oldPath = Join-Path $stateRoot 'game-tune-sessions/older/session.json'
        $newPath = Join-Path $stateRoot 'game-tune-sessions/current/session.json'
        foreach ($item in @(@{ path = $oldPath; id = 'legacy-before-first-write'; status = 'running'; restorable = $false; started = '2026-10-22T01:00:00Z' }, @{ path = $newPath; id = 'current-with-backup'; status = 'completed'; restorable = $true; started = '2026-10-23T01:00:00Z' })) {
            $data = Read-RooIndustriesJsonFile (Join-Path $Source 'backend/samples/game-tune-session-confirmed.sample.json')
            $data.sessionId = $item.id; $data.sessionPath = $item.path; $data.status = $item.status; $data.sessionStatus = $item.status; $data.startedAtUtc = $item.started; $data.restorable = $item.restorable
            $data.backupManifestPath = if ($item.restorable) { Join-Path (Split-Path $item.path -Parent) 'backup.json' } else { $null }
            if (-not $item.restorable) { $data.changedItems = @(); $data.pollCount = 0 }
            Write-RooIndustriesGameTuneJsonFile $data $item.path
            if ($item.restorable) { Write-RooIndustriesGameTuneJsonFile ([pscustomobject]@{ actionId = 'performance.gameTune.startSession'; dryRun = $false; backupId = 'current-backup'; sessionId = $item.id; profileId = $data.profileId; snapshots = @(@{ processId = 123; processName = 'FixtureGame.exe'; originalPriorityClass = 'Normal' }) }) $data.backupManifestPath }
        }
        $oldBytes = [IO.File]::ReadAllText($oldPath)
        $newBytes = [IO.File]::ReadAllText($newPath)
        foreach ($recover in @($false, $true, $true, $true)) {
            $status = & (Join-Path $engine 'Get-GameTuneSessionStatus.ps1') -StateRoot $stateRoot -RecoverInterrupted:$recover | ConvertFrom-Json
            $results.Add($status) | Out-Null
            Check ($status.sessionId -eq 'current-with-backup' -and $status.restorable -and -not $status.active -and -not $status.recoveryPerformed) "Upgrade refresh with recovery=$recover keeps the newer Restore"
        }
        $explicit = & (Join-Path $engine 'Get-GameTuneSessionStatus.ps1') -SessionPath $oldPath -RecoverInterrupted | ConvertFrom-Json
        Check ($explicit.sessionId -eq 'legacy-before-first-write' -and [IO.File]::ReadAllText($oldPath) -ceq $oldBytes -and [IO.File]::ReadAllText($newPath) -ceq $newBytes -and (Test-Path -LiteralPath (Join-Path (Split-Path $newPath -Parent) 'backup.json'))) 'The legacy record remains addressable and both journals and the current backup remain intact'
        $legacy = Read-RooIndustriesJsonFile $oldPath
        $global:RooIndustriesTuneFixture = @{ liveController = [pscustomobject]@{ StartTime = [datetime]'2026-10-23T00:00:00Z' } }
        $legacy | Add-Member ownerProcessId $PID
        $legacy | Add-Member ownerStartTimeUtc $global:RooIndustriesTuneFixture.liveController.StartTime.ToUniversalTime().ToString("yyyy/MM/dd HH:mm:ss.fffffff'Z'")
        Write-RooIndustriesGameTuneJsonFile $legacy $oldPath
        $live = & (Join-Path $engine 'Get-GameTuneSessionStatus.ps1') -StateRoot $stateRoot -RecoverInterrupted | ConvertFrom-Json
        Check ($live.sessionId -eq $legacy.sessionId -and $live.active) 'A verified live controller still takes active preference'
    }
} finally {
    [pscustomobject]@{ scenario = $Scenario; checks = @($checks.ToArray()); results = @($results.ToArray()) } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $Out 'result.json') -Encoding UTF8
    Remove-Variable -Name RooIndustriesTuneFixture -Scope Global -ErrorAction SilentlyContinue
}
$failed = @($checks | Where-Object { -not $_.passed }).Count
Write-Host "Game Tune ownership: $($checks.Count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
exit 0
