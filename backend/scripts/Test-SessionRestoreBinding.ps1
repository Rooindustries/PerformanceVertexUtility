$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
function Add-Check([bool]$Condition, [string]$Pass, [string]$Fail) {
    if ($Condition) { $passes.Add($Pass) | Out-Null; Write-Host "PASS $Pass" }
    else { $failures.Add($Fail) | Out-Null; Write-Host "FAIL $Fail" }
}
function Write-Json([string]$Path, [object]$Value) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Invoke-Stop([string]$Script, [string]$SessionId, [string]$SessionPath, [string]$BackupPath, [string]$OutputPath, [switch]$Confirm) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-SessionId', $SessionId, '-SessionPath', $SessionPath, '-BackupPath', $BackupPath, '-OutputPath', $OutputPath)
    if ($Confirm) { $arguments += '-ConfirmApply' }
    & powershell.exe @arguments | Out-Null
    $exitCode = $LASTEXITCODE
    $json = if (Test-Path -LiteralPath $OutputPath) { Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ ExitCode = $exitCode; Json = $json }
}
function New-SessionFixture([string]$Root, [string]$Kind, [string]$SessionId, [string]$ProfileId) {
    $directory = Join-Path $Root $SessionId
    $sessionPath = Join-Path $directory 'session.json'
    $backupPath = Join-Path $directory 'backup.json'
    $actionId = if ($Kind -eq 'game') { 'performance.gameTune.startSession' } else { 'performance.governor.startSession' }
    Write-Json $backupPath ([pscustomobject]@{
        schemaVersion = 1; backupId = "$Kind-$SessionId-backup"; actionId = $actionId
        sessionId = $SessionId; profileId = $ProfileId; dryRun = $false; snapshots = @()
    })
    Write-Json $sessionPath ([pscustomobject]@{
        schemaVersion = 1; sessionId = $SessionId; profileId = $ProfileId; dryRun = $false
        sessionStatus = 'completed'; status = 'completed'; sessionPath = $sessionPath
        backupManifestPath = $backupPath; restorable = $true; restoredItems = @(); skippedItems = @(); activeRestraints = @(); completedAtUtc = $null
    })
    return [pscustomobject]@{ SessionId = $SessionId; ProfileId = $ProfileId; SessionPath = $sessionPath; BackupPath = $backupPath }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$stateRoot = Join-Path $repoRoot 'backend\state'
$stateBefore = if (Test-Path -LiteralPath $stateRoot) { @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse).Count } else { 0 }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-session-binding-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    foreach ($kind in @('game', 'governor')) {
        $script = Join-Path $PSScriptRoot $(if ($kind -eq 'game') { 'Stop-GameTuneSession.ps1' } else { 'Stop-ProcessGovernorSession.ps1' })
        $a = New-SessionFixture $tempRoot $kind "$kind-a" "$kind-profile-a"
        $b = New-SessionFixture $tempRoot $kind "$kind-b" "$kind-profile-b"
        $aSessionHash = (Get-FileHash -LiteralPath $a.SessionPath -Algorithm SHA256).Hash
        $bSessionHash = (Get-FileHash -LiteralPath $b.SessionPath -Algorithm SHA256).Hash

        $matchedOutput = Join-Path $tempRoot "$kind-matched.json"
        $matched = Invoke-Stop $script $a.SessionId $a.SessionPath $a.BackupPath $matchedOutput
        Add-Check ($matched.ExitCode -eq 0 -and $matched.Json.status -eq 'preview' -and $matched.Json.sessionId -ceq $a.SessionId -and [string]::Equals([IO.Path]::GetFullPath($matched.Json.sessionPath), [IO.Path]::GetFullPath($a.SessionPath), [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([IO.Path]::GetFullPath($matched.Json.backupManifestPath), [IO.Path]::GetFullPath($a.BackupPath), [StringComparison]::OrdinalIgnoreCase)) "$kind restore preview retains exact session and backup identity" "$kind restore preview lost its exact session/backup identity"

        $mismatchOutput = Join-Path $tempRoot "$kind-mismatch.json"
        $mismatch = Invoke-Stop $script $b.SessionId $b.SessionPath $a.BackupPath $mismatchOutput
        Add-Check ($mismatch.ExitCode -ne 0 -and $mismatch.Json.status -eq 'failed' -and $mismatch.Json.errors[0].blocking -eq $true -and (Get-FileHash -LiteralPath $a.SessionPath -Algorithm SHA256).Hash -eq $aSessionHash -and (Get-FileHash -LiteralPath $b.SessionPath -Algorithm SHA256).Hash -eq $bSessionHash) "$kind restore rejects cross-session backup binding without changing either session" "$kind restore accepted or mutated a cross-session backup binding"

        $idMismatchOutput = Join-Path $tempRoot "$kind-id-mismatch.json"
        $idMismatch = Invoke-Stop $script $b.SessionId $a.SessionPath $a.BackupPath $idMismatchOutput
        Add-Check ($idMismatch.ExitCode -ne 0 -and $idMismatch.Json.status -eq 'failed' -and (Get-FileHash -LiteralPath $a.SessionPath -Algorithm SHA256).Hash -eq $aSessionHash) "$kind restore rejects a SessionId that disagrees with SessionPath and backup" "$kind restore accepted a mismatched SessionId"
        $backupBytes = [IO.File]::ReadAllBytes($a.BackupPath)
        foreach ($invalid in @('wrong-action','dry-run','missing-dry-run')) {
            $changedBackup = Get-Content -LiteralPath $a.BackupPath -Raw | ConvertFrom-Json
            if ($invalid -eq 'wrong-action') { $changedBackup.actionId = 'performance.applyProfile' }
            elseif ($invalid -eq 'dry-run') { $changedBackup.dryRun = $true }
            else { $changedBackup.PSObject.Properties.Remove('dryRun') }
            Write-Json $a.BackupPath $changedBackup
            $invalidResult = Invoke-Stop $script $a.SessionId $a.SessionPath $a.BackupPath (Join-Path $tempRoot "$kind-$invalid.json") -Confirm
            Add-Check ($invalidResult.ExitCode -ne 0 -and $invalidResult.Json.status -eq 'failed' -and (Get-FileHash -LiteralPath $a.SessionPath -Algorithm SHA256).Hash -eq $aSessionHash) "$kind rejects $invalid backup before updating the session" "$kind accepted $invalid backup"
            [IO.File]::WriteAllBytes($a.BackupPath, $backupBytes)
        }
        $retry = New-SessionFixture $tempRoot $kind "$kind-retry" "$kind-retry-profile"
        $retryBackup = Get-Content -LiteralPath $retry.BackupPath -Raw | ConvertFrom-Json
        $retryBackup.snapshots = @([pscustomobject]@{ processId=2147483646; processName='RooIndustriesAbsentSessionFixture'; executablePath=(Join-Path $tempRoot 'never-created.exe'); originalPriorityClass='Normal'; processStartTimeUtc='2000-01-01T00:00:00Z' })
        Write-Json $retry.BackupPath $retryBackup
        $failedRestore = Invoke-Stop $script $retry.SessionId $retry.SessionPath $retry.BackupPath (Join-Path $tempRoot "$kind-incomplete.json") -Confirm
        $retrySaved = Get-Content -LiteralPath $retry.SessionPath -Raw | ConvertFrom-Json
        Add-Check ($failedRestore.Json.result.status -eq 'failed' -and $failedRestore.Json.restorable -and $retrySaved.restorable -and $failedRestore.Json.result.changedItems.Count -eq 0) "$kind incomplete restore preserves its recovery record without changing a process" "$kind incomplete restore discarded recovery evidence"
        $confirmedOutput = Join-Path $tempRoot "$kind-confirmed.json"
        $confirmed = Invoke-Stop $script $a.SessionId $a.SessionPath $a.BackupPath $confirmedOutput -Confirm
        $saved = Get-Content -LiteralPath $a.SessionPath -Raw | ConvertFrom-Json
        Add-Check ($confirmed.ExitCode -eq 0 -and -not $confirmed.Json.dryRun -and $confirmed.Json.result.status -eq 'rolledBack' -and $confirmed.Json.sessionPath -eq $a.SessionPath -and -not $saved.restorable -and $saved.status -eq 'completed') "$kind confirmed empty restore updates the exact session record" "$kind confirmed empty restore failed to update its session record"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
$stateAfter = if (Test-Path -LiteralPath $stateRoot) { @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse).Count } else { 0 }
Add-Check ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) 'Session binding fixtures leave backend/state empty' "Session binding fixtures changed backend/state: before=$stateBefore after=$stateAfter"
Add-Check (-not (Test-Path -LiteralPath $tempRoot)) 'Session binding fixtures remove their temporary files' 'Session binding fixture files remain'

if ($failures.Count -gt 0) {
    Write-Host "FAIL Session restore binding validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
    exit 1
}
Write-Host "PASS Session restore binding validation completed. $($passes.Count) checks passed."
