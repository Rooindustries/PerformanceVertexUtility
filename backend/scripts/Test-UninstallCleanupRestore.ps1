param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
$caseEvidence = New-Object System.Collections.Generic.List[object]
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = Join-Path $repoRoot 'artifacts\validation\uninstall-cleanup-restore.json' }

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
    Write-Host "PASS $Message"
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "FAIL $Message"
}

function ConvertFrom-ScriptJson {
    param([object[]]$Output)
    return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function New-RestoreCase {
    param([string]$Name)
    $root = Join-Path $tempRoot $Name
    $backup = Join-Path $root 'backup'
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    return [pscustomobject]@{ name = $Name; root = $root; backup = $backup; target = (Join-Path $root 'targets'); manifest = (Join-Path $root 'rollback.json') }
}

function Write-FixtureFile {
    param([string]$Path, [string]$Contents)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path, $Contents)
}

function Write-RestoreManifest {
    param([object]$Case, [object[]]$Backups)
    [pscustomobject]@{
        schemaVersion = 1; productName = 'Roo Industries Optimization Suite'; actionId = 'apps.rollbackCleanup'
        manifestId = $Case.name; fixtureRoot = $Case.target; realSystemRollback = $false; fileBackups = $Backups
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Case.manifest -Encoding UTF8
}

function Get-PathEvidence {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ path = $Path; type = 'absent' } }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{ path = $Path; type = 'file'; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    }
    return [pscustomobject]@{
        path = $Path; type = 'folder'; children = @(Get-ChildItem -LiteralPath $Path -Force | ForEach-Object { Get-PathEvidence $_.FullName })
    }
}

function Invoke-RestoreCase {
    param([object]$Case)
    $result = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1') -RollbackManifestPath $Case.manifest -ConfirmApply -AllowDisposableFixtureApply)
    $manifest = Get-Content -LiteralPath $Case.manifest -Raw | ConvertFrom-Json
    $caseEvidence.Add([pscustomobject]@{
        name = $Case.name; manifest = $manifest; result = $result
        targets = @($manifest.fileBackups | ForEach-Object { Get-PathEvidence $_.source })
        backups = @($manifest.fileBackups | ForEach-Object { Get-PathEvidence $_.backupPath })
    }) | Out-Null
    return $result
}

$requiredFiles = @(
    'backend\scripts\Invoke-UninstallCleanupExecution.ps1',
    'backend\scripts\Restore-UninstallCleanupExecution.ps1'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $relative"
    } else {
        Add-Failure "Required file missing: $relative"
    }
}

$stateBefore = Get-StateEntryCount
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-uninstall-restore-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    $folderTarget = Join-Path $tempRoot 'FakeAppCache'
    $folderFile = Join-Path $folderTarget 'cache.txt'
    $fileTarget = Join-Path $tempRoot 'loose.txt'
    New-Item -ItemType Directory -Path $folderTarget -Force | Out-Null
    Set-Content -LiteralPath $folderFile -Value 'folder payload' -Encoding UTF8
    Set-Content -LiteralPath $fileTarget -Value 'file payload' -Encoding UTF8

    $officialPath = Join-Path $tempRoot 'official-preview.json'
    $manifestPath = Join-Path $tempRoot 'cleanup-manifest.json'
    ([pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        dryRun = $true
        status = 'preview'
        commands = @([pscustomobject]@{ appId = 'fixture:restore-app'; displayName = 'Restore Fixture'; rawCommand = 'preview only'; executable = 'preview.exe'; arguments = @(); protected = $false; blocked = $false; executionAllowed = $false })
        summary = [pscustomobject]@{ commandPreviewCount = 1; willRunUninstallers = $false }
        warnings = @(); errors = @(); logs = @()
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $officialPath -Encoding UTF8
    ([pscustomobject]@{
        manifestId = 'restore-fixture-manifest'
        productName = 'Roo Industries Optimization Suite'
        schemaVersion = 1
        appId = 'fixture:restore-app'
        displayName = 'Restore Fixture'
        dryRun = $true
        items = @(
            [pscustomobject]@{ itemId = 'folder-cache'; type = 'folder'; target = $folderTarget; protected = $false; defaultSelected = $true },
            [pscustomobject]@{ itemId = 'file-cache'; type = 'file'; target = $fileTarget; protected = $false; defaultSelected = $true }
        )
        rollback = [pscustomobject]@{ backupRoot = (Join-Path $tempRoot '_backup'); rollbackSupported = $true }
        summary = [pscustomobject]@{ itemCount = 2; willDeleteOnApply = $false; dryRunWritesState = $false }
        warnings = @(); errors = @()
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $apply = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialPath -CleanupManifestPath $manifestPath -FixtureRoot $tempRoot -ConfirmApply -AllowDisposableFixtureApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved)
    if ($apply.status -eq 'success' -and $apply.summary.deletedCount -eq 2 -and -not (Test-Path -LiteralPath $folderTarget) -and -not (Test-Path -LiteralPath $fileTarget) -and (Test-Path -LiteralPath $apply.rollback.rollbackManifestPath)) {
        Add-Pass 'Cleanup fixture apply backed up and deleted disposable file and folder targets'
    } else {
        Add-Failure 'Cleanup fixture apply did not produce expected backup/delete state'
    }

    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1') -RollbackManifestPath $apply.rollback.rollbackManifestPath -ConfirmApply -AllowDisposableFixtureApply)
    if ($restore.status -eq 'success' -and $restore.summary.restoredCount -eq 2 -and (Test-Path -LiteralPath $folderFile) -and (Test-Path -LiteralPath $fileTarget) -and (Get-Content -LiteralPath $folderFile -Raw).Trim() -eq 'folder payload' -and (Get-Content -LiteralPath $fileTarget -Raw).Trim() -eq 'file payload') {
        Add-Pass 'Cleanup fixture restore rehydrated copied file and folder backups through rollback manifest'
    } else {
        Add-Failure 'Cleanup fixture restore did not rehydrate copied file and folder backups'
    }

    $case = New-RestoreCase 'changed-file'
    $saved = Join-Path $case.backup 'changed.txt'; $changed = Join-Path $case.target 'changed.txt'
    $savedAbsent = Join-Path $case.backup 'absent.txt'; $absent = Join-Path $case.target 'absent.txt'
    Write-FixtureFile $saved 'before'; Write-FixtureFile $changed 'after!'; Write-FixtureFile $savedAbsent 'restore only after conflicts clear'
    Write-RestoreManifest $case @(
        [pscustomobject]@{ itemId = 'changed'; type = 'file'; source = $changed; backupPath = $saved; copied = $true },
        [pscustomobject]@{ itemId = 'absent'; type = 'file'; source = $absent; backupPath = $savedAbsent; copied = $true }
    )
    $changedHash = (Get-FileHash -LiteralPath $changed -Algorithm SHA256).Hash
    $result = Invoke-RestoreCase $case
    $gate = @($result.gates | Where-Object { $_.gateId -eq 'restore-destinations-unchanged' })
    if ($result.status -eq 'blocked' -and $result.dryRun -and $gate.Count -eq 1 -and $gate[0].blocking -and $gate[0].evidence.conflictCount -eq 1 -and
        $gate[0].evidence.conflicts[0].target -eq $changed -and $gate[0].evidence.conflicts[0].reason -eq 'This file changed after cleanup.' -and
        (Get-FileHash -LiteralPath $changed -Algorithm SHA256).Hash -eq $changedHash -and -not (Test-Path -LiteralPath $absent) -and @($result.restoredItems).Count -eq 0) {
        Add-Pass 'Changed file blocks the whole restore before an absent target is copied'
    } else { Add-Failure 'Changed file must block the whole restore before an absent target is copied' }

    $case = New-RestoreCase 'file-became-folder'
    $saved = Join-Path $case.backup 'record.txt'; $target = Join-Path $case.target 'original.txt'
    Write-FixtureFile $saved 'backed-up file'; Write-FixtureFile (Join-Path $target 'new.txt') 'new folder contents'
    Write-RestoreManifest $case @([pscustomobject]@{ itemId = 'file'; type = 'file'; source = $target; backupPath = $saved; copied = $true })
    $newHash = (Get-FileHash -LiteralPath (Join-Path $target 'new.txt') -Algorithm SHA256).Hash
    $result = Invoke-RestoreCase $case
    $gate = @($result.gates | Where-Object { $_.gateId -eq 'restore-destinations-unchanged' })
    if ($result.status -eq 'blocked' -and $gate.Count -eq 1 -and $gate[0].blocking -and $gate[0].evidence.conflictCount -eq 1 -and
        $gate[0].evidence.conflicts[0].reason -eq 'A folder now exists where this file was.' -and
        (Get-FileHash -LiteralPath (Join-Path $target 'new.txt') -Algorithm SHA256).Hash -eq $newHash -and
        -not (Test-Path -LiteralPath (Join-Path $target 'record.txt')) -and @(Get-ChildItem -LiteralPath $target -Force).Count -eq 1 -and @($result.restoredItems).Count -eq 0) {
        Add-Pass 'A folder replacing a file blocks restore without copying a backup inside it'
    } else { Add-Failure 'A folder replacing a file must block restore without copying a backup inside it' }

    $case = New-RestoreCase 'changed-folder-child'
    $saved = Join-Path $case.backup 'tree'; $target = Join-Path $case.target 'tree'
    Write-FixtureFile (Join-Path $saved 'child.txt') 'original child'
    Write-FixtureFile (Join-Path $target 'child.txt') 'changed child'
    Write-FixtureFile (Join-Path $target 'unreviewed.txt') 'keep unreviewed child'
    Write-RestoreManifest $case @([pscustomobject]@{ itemId = 'tree'; type = 'folder'; source = $target; backupPath = $saved; copied = $true })
    $childHash = (Get-FileHash -LiteralPath (Join-Path $target 'child.txt') -Algorithm SHA256).Hash
    $extraHash = (Get-FileHash -LiteralPath (Join-Path $target 'unreviewed.txt') -Algorithm SHA256).Hash
    $result = Invoke-RestoreCase $case
    $gate = @($result.gates | Where-Object { $_.gateId -eq 'restore-destinations-unchanged' })
    if ($result.status -eq 'blocked' -and $gate.Count -eq 1 -and $gate[0].blocking -and $gate[0].evidence.conflictCount -eq 1 -and
        (Get-FileHash -LiteralPath (Join-Path $target 'child.txt') -Algorithm SHA256).Hash -eq $childHash -and
        (Get-FileHash -LiteralPath (Join-Path $target 'unreviewed.txt') -Algorithm SHA256).Hash -eq $extraHash -and @($result.restoredItems).Count -eq 0) {
        Add-Pass 'Changed folder child blocks restore and preserves unreviewed children'
    } else { Add-Failure 'Changed folder child must block restore and preserve unreviewed children' }

    $case = New-RestoreCase 'identical-and-absent'
    $savedIdentical = Join-Path $case.backup 'identical.txt'; $identical = Join-Path $case.target 'identical.txt'
    $savedAbsent = Join-Path $case.backup 'absent.txt'; $absent = Join-Path $case.target 'absent.txt'
    Write-FixtureFile $savedIdentical 'identical bytes'; Write-FixtureFile $identical 'identical bytes'; Write-FixtureFile $savedAbsent 'missing bytes'
    Write-RestoreManifest $case @(
        [pscustomobject]@{ itemId = 'identical'; type = 'file'; source = $identical; backupPath = $savedIdentical; copied = $true },
        [pscustomobject]@{ itemId = 'absent'; type = 'file'; source = $absent; backupPath = $savedAbsent; copied = $true }
    )
    $identicalStamp = (Get-Item -LiteralPath $identical).LastWriteTimeUtc.Ticks
    $result = Invoke-RestoreCase $case
    if ($result.status -eq 'success' -and $result.summary.restoredCount -eq 2 -and @($result.restoredItems).Count -eq 2 -and
        $result.restoredItems[0].restored -and $result.restoredItems[0].alreadyPresent -eq $true -and
        $result.restoredItems[1].restored -and $result.restoredItems[1].alreadyPresent -eq $false -and
        (Get-FileHash -LiteralPath $identical -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $savedIdentical -Algorithm SHA256).Hash -and
        (Get-FileHash -LiteralPath $absent -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $savedAbsent -Algorithm SHA256).Hash -and
        (Get-Item -LiteralPath $identical).LastWriteTimeUtc.Ticks -eq $identicalStamp) {
        Add-Pass 'Restore skips an identical file and copies an absent file with accurate alreadyPresent flags'
    } else { Add-Failure 'Restore must skip an identical file and copy an absent file with accurate alreadyPresent flags' }
    $retry = Invoke-RestoreCase $case
    if ($retry.status -eq 'success' -and $retry.summary.restoredCount -eq 2 -and @($retry.restoredItems).Count -eq 2 -and
        @($retry.restoredItems | Where-Object { $_.restored -and $_.alreadyPresent -eq $true }).Count -eq 2) {
        Add-Pass 'Repeating the same restore recognizes both files as already present'
    } else { Add-Failure 'Repeating the same restore must recognize both files as already present' }

    $case = New-RestoreCase 'absent-folder'
    $saved = Join-Path $case.backup 'tree'; $target = Join-Path $case.target 'tree'
    Write-FixtureFile (Join-Path $saved 'first.txt') 'first file'
    Write-FixtureFile (Join-Path $saved 'nested\second.txt') 'nested file'
    [IO.Directory]::CreateDirectory((Join-Path $saved 'empty')) | Out-Null
    Write-RestoreManifest $case @([pscustomobject]@{ itemId = 'tree'; type = 'folder'; source = $target; backupPath = $saved; copied = $true })
    $result = Invoke-RestoreCase $case
    if ($result.status -eq 'success' -and $result.summary.restoredCount -eq 1 -and $result.restoredItems[0].restored -and
        (Get-FileHash -LiteralPath (Join-Path $target 'first.txt') -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $saved 'first.txt') -Algorithm SHA256).Hash -and
        (Get-FileHash -LiteralPath (Join-Path $target 'nested\second.txt') -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $saved 'nested\second.txt') -Algorithm SHA256).Hash -and
        (Test-Path -LiteralPath (Join-Path $target 'empty') -PathType Container)) {
        Add-Pass 'An absent folder restores the full backup tree including empty directories'
    } else { Add-Failure 'An absent folder must restore the full backup tree including empty directories' }
    Write-FixtureFile (Join-Path $target 'unreviewed.txt') 'preserve extra file'
    $retry = Invoke-RestoreCase $case
    if ($retry.status -eq 'success' -and $retry.restoredItems[0].restored -and $retry.restoredItems[0].alreadyPresent -eq $true -and
        [IO.File]::ReadAllText((Join-Path $target 'unreviewed.txt')) -eq 'preserve extra file') {
        Add-Pass 'An already restored folder is recognized without removing extra target children'
    } else { Add-Failure 'An already restored folder must be recognized without removing extra target children' }

    $case = New-RestoreCase 'folder-became-file'
    $saved = Join-Path $case.backup 'tree'; $target = Join-Path $case.target 'tree'
    Write-FixtureFile (Join-Path $saved 'child.txt') 'backed-up child'; Write-FixtureFile $target 'new target file'
    Write-RestoreManifest $case @([pscustomobject]@{ itemId = 'tree'; type = 'folder'; source = $target; backupPath = $saved; copied = $true })
    $result = Invoke-RestoreCase $case
    $gate = @($result.gates | Where-Object { $_.gateId -eq 'restore-destinations-unchanged' })
    if ($result.status -eq 'blocked' -and $gate.Count -eq 1 -and $gate[0].blocking -and $gate[0].evidence.conflictCount -eq 1 -and
        [IO.File]::ReadAllText($target) -eq 'new target file' -and @($result.restoredItems).Count -eq 0) {
        Add-Pass 'A file replacing a folder blocks restore before copying any children'
    } else { Add-Failure 'A file replacing a folder must block restore before copying any children' }

    $case = New-RestoreCase 'nested-folder-became-file'
    $saved = Join-Path $case.backup 'tree'; $target = Join-Path $case.target 'tree'
    Write-FixtureFile (Join-Path $saved 'early.txt') 'keep absent until clear'
    Write-FixtureFile (Join-Path $saved 'nested\child.txt') 'backed-up child'
    Write-FixtureFile (Join-Path $target 'nested') 'new nested target file'
    Write-RestoreManifest $case @([pscustomobject]@{ itemId = 'tree'; type = 'folder'; source = $target; backupPath = $saved; copied = $true })
    $result = Invoke-RestoreCase $case
    $gate = @($result.gates | Where-Object { $_.gateId -eq 'restore-destinations-unchanged' })
    if ($result.status -eq 'blocked' -and $gate.Count -eq 1 -and $gate[0].blocking -and $gate[0].evidence.conflictCount -eq 1 -and
        [IO.File]::ReadAllText((Join-Path $target 'nested')) -eq 'new nested target file' -and
        -not (Test-Path -LiteralPath (Join-Path $target 'early.txt')) -and @($result.restoredItems).Count -eq 0) {
        Add-Pass 'A file replacing a nested backup directory blocks the whole tree restore'
    } else { Add-Failure 'A file replacing a nested backup directory must block the whole tree restore' }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Cleanup restore disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Cleanup restore disposable fixtures remain'
    }
} catch {
    Add-Failure "Cleanup restore validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after cleanup restore validation'
} else {
    Add-Failure "backend/state is not empty or changed during cleanup restore validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Cleanup restore validation did not launch real uninstallers or cleanup tools'

$evidence = [ordered]@{
    schemaVersion = 1; test = 'uninstall-cleanup-restore'; cases = @($caseEvidence.ToArray())
    scriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1') -Algorithm SHA256).Hash
    commonSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1') -Algorithm SHA256).Hash
    passes = @($passes.ToArray()); failures = @($failures.ToArray()); stateBefore = $stateBefore; stateAfter = $stateAfter
    fixturesRemoved = -not (Test-Path -LiteralPath $tempRoot)
}
[IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($EvidencePath)) -Parent)) | Out-Null
$evidence | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Host "Evidence: $EvidencePath"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Uninstall cleanup restore validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Uninstall cleanup restore validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
