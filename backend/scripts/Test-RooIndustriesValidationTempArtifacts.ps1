$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

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

$required = Join-Path $repoRoot 'backend\scripts\Get-RooIndustriesValidationTempArtifacts.ps1'
if (Test-Path -LiteralPath $required) {
    Add-Pass 'Required file exists: backend\scripts\Get-RooIndustriesValidationTempArtifacts.ps1'
} else {
    Add-Failure 'Required file missing: backend\scripts\Get-RooIndustriesValidationTempArtifacts.ps1'
}

$stateBefore = Get-StateEntryCount
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-validation-temp-audit-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $oldArtifact = Join-Path $tempRoot 'roo-industries-stutter-old-artifact'
    $activeArtifact = Join-Path $tempRoot 'roo-industries-stutter-active-artifact'
    New-Item -ItemType Directory -Path $oldArtifact -Force | Out-Null
    New-Item -ItemType Directory -Path $activeArtifact -Force | Out-Null
    'old' | Set-Content -LiteralPath (Join-Path $oldArtifact 'marker.txt') -Encoding UTF8
    'active' | Set-Content -LiteralPath (Join-Path $activeArtifact 'marker.txt') -Encoding UTF8
    $oldTime = (Get-Date).AddMinutes(-180)
    (Get-Item -LiteralPath $oldArtifact).LastWriteTime = $oldTime
    (Get-Item -LiteralPath (Join-Path $oldArtifact 'marker.txt')).LastWriteTime = $oldTime

    $report = ConvertFrom-ScriptJson (& $required -ArtifactRoot $tempRoot -MinimumAgeMinutes 60 -ProtectPath $activeArtifact)
    if ($report.dryRun -eq $true -and $report.summary.artifactCount -eq 2 -and $report.summary.oldUnprotectedCount -eq 1 -and $report.summary.deletedCount -eq 0 -and (Test-Path -LiteralPath $oldArtifact) -and (Test-Path -LiteralPath $activeArtifact)) {
        Add-Pass 'Temp artifact audit reports old artifacts without deleting by default'
    } else {
        Add-Failure 'Temp artifact audit dry-run did not preserve artifacts or report expected counts'
    }

    $cleanup = ConvertFrom-ScriptJson (& $required -ArtifactRoot $tempRoot -MinimumAgeMinutes 60 -ProtectPath $activeArtifact -Cleanup)
    if ($cleanup.dryRun -eq $false -and $cleanup.summary.deletedCount -eq 1 -and -not (Test-Path -LiteralPath $oldArtifact) -and (Test-Path -LiteralPath $activeArtifact)) {
        Add-Pass 'Temp artifact audit cleanup deletes only old unprotected artifacts after explicit flag'
    } else {
        Add-Failure 'Temp artifact audit cleanup did not delete only the old unprotected artifact'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Temp artifact audit fixtures were cleaned up'
    } else {
        Add-Failure 'Temp artifact audit fixtures remain'
    }
} catch {
    Add-Failure "Temp artifact audit validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after temp artifact audit validation'
} else {
    Add-Failure "backend/state is not empty or changed during temp artifact audit validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Temp artifact audit validation did not launch frontend, NVPI, Revo, FSOS, AME, WinUtil, registry, service, driver, or cleanup utilities'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Validation temp artifact audit completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Validation temp artifact audit failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
