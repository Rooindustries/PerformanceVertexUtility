param(
    [string]$Source,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'
if (-not $Source) { $Source = Join-Path $PSScriptRoot '../../..' }
$checks = New-Object System.Collections.Generic.List[object]
$engine = Join-Path $Out 'engine'
New-Item -ItemType Directory -Path $engine -Force | Out-Null
Copy-Item -Path (Join-Path $Source 'backend/scripts/*.ps1') -Destination $engine
@'
if ($env:ROO_INDUSTRIES_APPLY_FIXTURE) { $global:RooIndustriesApplyFixture = Get-Content -LiteralPath $env:ROO_INDUSTRIES_APPLY_FIXTURE -Raw | ConvertFrom-Json }
function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    $process = @($global:RooIndustriesApplyFixture.processes | Where-Object processId -eq $Id)
    if ($process.Count -eq 1) { return [pscustomobject]@{ Id = $Id; ProcessName = $process[0].processName; Path = $process[0].path; PriorityClass = $process[0].state.priorityClass } }
}
function Get-RooIndustriesProcessControlState {
    param($ProcessId, $Unused, [switch]$ReadGpu)
    return @($global:RooIndustriesApplyFixture.processes | Where-Object processId -eq $ProcessId)[0].state
}
function Invoke-RooIndustriesProcessControlChange {
    param($Process, $Change)
    $fixture = $global:RooIndustriesApplyFixture
    $fixture.attempts++
    if ($fixture.attempts -eq $fixture.cutAt) { [Environment]::Exit(137) }
    $Change | Add-Member -NotePropertyName outcome -NotePropertyValue 'pending' -Force
    @($fixture.processes | Where-Object processId -eq $Process.Id)[0].state.($Change.control) = $Change.proposedValue
    Add-Content -LiteralPath $env:ROO_INDUSTRIES_APPLY_WRITES -Value ([string]$Process.Id + '|' + $Change.control)
    $Change.outcome = 'applied'
}
'@ | Add-Content -LiteralPath (Join-Path $engine 'ProcessProfile.Common.ps1')
@'
param([string]$ProfilePath, [string]$Preset, [string]$TargetGameProcessName)
$global:RooIndustriesApplyFixture.preview | ConvertTo-Json -Depth 20
'@ | Set-Content -LiteralPath (Join-Path $engine 'Preview-ProcessProfile.ps1')
. (Join-Path $Source 'backend/scripts/ProcessProfile.Common.ps1')

function Check([bool]$Condition, [string]$Message) {
    $checks.Add([pscustomobject]@{ passed = $Condition; message = $Message }) | Out-Null
    Write-Host "$(if ($Condition) { 'PASS' } else { 'FAIL' }) $Message"
}

function Invoke-CutApply {
    param([string]$Name, [int]$CutAt)
    $directory = Join-Path $Out $Name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $original = @{ priorityClass = 'Normal'; memoryPriority = 5 }
    $planned = @{ priorityClass = 'BelowNormal'; memoryPriority = 2 }
    $processes = @(4101, 4102) | ForEach-Object {
        [pscustomobject]@{ processId = $_; processName = "CutFixture$_.exe"; path = "C:\Fixtures\CutFixture$_.exe"; state = [pscustomobject]@{ priorityClass = $original.priorityClass; memoryPriority = $original.memoryPriority; memoryPriorityAvailable = $true; startTimeUtc = '2026-10-23 10:00:00Z' } }
    }
    $preview = [pscustomobject]@{ preview = @($processes | ForEach-Object {
        [pscustomobject]@{
            processId = $_.processId; processName = $_.processName; executablePath = $_.path; processStartTimeUtc = $_.state.startTimeUtc
            currentPriorityClass = $original.priorityClass; proposedPriorityClass = $planned.priorityClass; currentMemoryPriority = $original.memoryPriority; proposedMemoryPriority = $planned.memoryPriority
            controlChanges = @(
                (New-RooIndustriesControlChange 'priorityClass' $original.priorityClass $planned.priorityClass 'setPriority' 'Lower background app.'),
                (New-RooIndustriesControlChange 'memoryPriority' $original.memoryPriority $planned.memoryPriority 'setMemoryPriority' 'Lower background app memory priority.'))
            ruleId = 'cut-fixture'; reason = 'Disposable cut fixture.'; blocked = $false; protected = $false
        }
    }); warnings = @(); errors = @() }
    $fixturePath = Join-Path $directory 'fixture.json'
    $writesPath = Join-Path $directory 'writes.txt'
    $profilePath = Join-Path $directory 'profile.json'
    $state = Join-Path $directory 'state'
    [pscustomobject]@{ cutAt = $CutAt; attempts = 0; processes = $processes; preview = $preview } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixturePath
    [pscustomobject]@{ schemaVersion = 1; profileId = 'cut'; name = 'Cut fixture'; risk = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath $profilePath
    New-Item -ItemType File -Path $writesPath -Force | Out-Null
    $env:ROO_INDUSTRIES_APPLY_FIXTURE = $fixturePath
    $env:ROO_INDUSTRIES_APPLY_WRITES = $writesPath
    try {
        & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -File (Join-Path $engine 'Apply-ProcessProfile.ps1') -ProfilePath $profilePath -StateRoot $state -OutputPath (Join-Path $directory 'apply.json') -ConfirmApply | Out-Null
        $exit = $LASTEXITCODE
    } finally {
        Remove-Item Env:\ROO_INDUSTRIES_APPLY_FIXTURE, Env:\ROO_INDUSTRIES_APPLY_WRITES -ErrorAction SilentlyContinue
    }
    Check ($exit -eq $(if ($CutAt -gt 0) { 137 } else { 0 })) "$Name apply ends the way the case needs (exit $exit)"
    $backupFile = @(Get-ChildItem -LiteralPath (Join-Path $state 'process-profile-backups') -Filter 'backup.json' -Recurse -File)
    Check ($backupFile.Count -eq 1) "$Name leaves one backup on disk"
    if ($backupFile.Count -ne 1) { return }
    $backup = Read-RooIndustriesJsonFile $backupFile[0].FullName
    $written = @(Get-Content -LiteralPath $writesPath | Where-Object { $_ })
    foreach ($process in $processes) {
        $snapshot = @($backup.snapshots | Where-Object processId -eq $process.processId)[0]
        $live = [pscustomobject]@{ priorityClass = $original.priorityClass; memoryPriority = $original.memoryPriority; memoryPriorityAvailable = $true; exists = $true }
        foreach ($control in 'priorityClass', 'memoryPriority') {
            if ($written -contains ([string]$process.processId + '|' + $control)) { $live.$control = $planned.$control }
        }
        foreach ($control in 'priorityClass', 'memoryPriority') {
            $applied = Get-RooIndustriesAppliedControlValue $snapshot $control
            $action = if ($control -eq 'priorityClass') { 'restorePriority' } else { 'restoreMemoryPriority' }
            $restore = New-RooIndustriesControlChange $control $live.$control $original.$control $action 'Restore the original value.'
            $split = Split-RooIndustriesLeftAsSetRestoreChanges $snapshot @($restore) $live
            if ($written -contains ([string]$process.processId + '|' + $control)) {
                Check ($applied.verified -and @($split.changes | Where-Object { -not $_.blocked }).Count -eq 1) "$Name lets Restore undo $($process.processName) $control the apply wrote"
            } else {
                Check (-not $applied.verified -and @($split.alreadyOriginal).Count -eq 1 -and @($split.changes).Count -eq 0) "$Name keeps $($process.processName) $control the apply never wrote at its original without a write"
            }
        }
    }
}

try {
    Invoke-CutApply 'cut-inside-process' 2
    Invoke-CutApply 'cut-between-processes' 3
    Invoke-CutApply 'full' 0
} finally {
    [pscustomobject]@{ checks = @($checks.ToArray()) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Out 'result.json') -Encoding UTF8
}
$failed = @($checks | Where-Object { -not $_.passed }).Count
Write-Host "Interrupted apply journal: $($checks.Count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
exit 0
