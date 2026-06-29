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

function Test-JsonFile {
    param([string]$Path)
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
        Add-Pass "JSON parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } catch {
        Add-Failure "JSON parse failed: $Path :: $($_.Exception.Message)"
    }
}

function Test-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $RelativePath"
    } else {
        Add-Failure "Required file missing: $RelativePath"
    }
}

function Invoke-JsonScript {
    param(
        [string]$ScriptPath,
        [object[]]$Arguments = @()
    )
    $output = & $ScriptPath @Arguments
    return $output | ConvertFrom-Json
}

$requiredFiles = @(
    'backend\profiles\game-session.profile.json',
    'backend\profiles\protected-processes.json',
    'backend\profiles\background-demotion.profile.json',
    'backend\scripts\ProcessProfile.Common.ps1',
    'backend\scripts\Get-ProcessClassification.ps1',
    'backend\scripts\Preview-ProcessProfile.ps1',
    'backend\scripts\Apply-ProcessProfile.ps1',
    'backend\scripts\Restore-ProcessProfileBackup.ps1',
    'backend\samples\process-classification.sample.json',
    'backend\samples\process-profile-preview.sample.json',
    'backend\samples\process-profile-dry-run-result.sample.json',
    'backend\samples\process-profile-rollback-preview.sample.json',
    'backend\samples\process-profile-backup.sample.json'
)

foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

$jsonRoots = @(
    (Join-Path $repoRoot 'modules'),
    (Join-Path $repoRoot 'backend')
)

foreach ($root in $jsonRoots) {
    if (Test-Path -LiteralPath $root) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File) {
            Test-JsonFile $file.FullName
        }
    }
}

try {
    $catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'backend\profiles\protected-processes.json') -Raw | ConvertFrom-Json
    $requiredCategories = @(
        'windows-core',
        'security',
        'network',
        'audio-input',
        'anti-cheat',
        'gpu-driver',
        'windows-app-dependency',
        'samsung-continuity',
        'protected-companion'
    )
    $catalogCategories = @($catalog.protectedProcesses | Select-Object -ExpandProperty category -Unique)
    foreach ($category in $requiredCategories) {
        if ($catalogCategories -contains $category) {
            Add-Pass "Protected process category exists: $category"
        } else {
            Add-Failure "Protected process category missing: $category"
        }
    }
} catch {
    Add-Failure "Protected process catalog validation failed: $($_.Exception.Message)"
}

try {
    $inventory = Invoke-JsonScript (Join-Path $PSScriptRoot 'Get-ProcessInventory.ps1')
    if ($inventory.productName -eq 'Roo Industries Optimization Suite' -and $inventory.summary.processCount -gt 0) {
        Add-Pass "Process inventory returned $($inventory.summary.processCount) processes"
    } else {
        Add-Failure "Process inventory returned an unexpected shape"
    }
} catch {
    Add-Failure "Process inventory failed: $($_.Exception.Message)"
}

try {
    $classification = & (Join-Path $PSScriptRoot 'Get-ProcessClassification.ps1') -ProfilePath (Join-Path $repoRoot 'backend\profiles\game-session.profile.json') | ConvertFrom-Json
    $allowedClasses = @('gameTarget', 'protected', 'protectedCompanion', 'safeCandidate', 'demotionCandidate', 'unknown')
    $badClass = @($classification.processes | Where-Object { $_.classification -notin $allowedClasses }) | Select-Object -First 1
    if ($classification.productName -eq 'Roo Industries Optimization Suite' -and $classification.summary.processCount -gt 0 -and $null -eq $badClass) {
        Add-Pass "Process classification returned $($classification.summary.processCount) classified processes"
    } else {
        Add-Failure "Process classification returned an unexpected shape or class"
    }
} catch {
    Add-Failure "Process classification failed: $($_.Exception.Message)"
}

try {
    $preview = & (Join-Path $PSScriptRoot 'Preview-ProcessProfile.ps1') -ProfilePath (Join-Path $repoRoot 'backend\profiles\game-session.profile.json') | ConvertFrom-Json
    if ($preview.actionId -eq 'performance.previewProfile' -and $preview.status -eq 'preview' -and $preview.dryRun -eq $true) {
        Add-Pass "Game Session preview returned a structured action envelope"
    } else {
        Add-Failure "Game Session preview returned an unexpected envelope"
    }
    if ($null -eq $preview.backup) {
        Add-Pass "Preview backup is null"
    } else {
        Add-Failure "Preview backup should be null"
    }
    $unsafeProtected = @($preview.preview | Where-Object { $_.protected -eq $true -and $_.proposedAction -ne 'noChange' })
    if ($unsafeProtected.Count -eq 0) {
        Add-Pass "Preview does not propose changing protected processes"
    } else {
        Add-Failure "Preview proposed changing protected process entries"
    }
} catch {
    Add-Failure "Game Session preview failed: $($_.Exception.Message)"
}

try {
    $dryRunApply = & (Join-Path $PSScriptRoot 'Apply-ProcessProfile.ps1') -ProfilePath (Join-Path $repoRoot 'backend\profiles\game-session.profile.json') | ConvertFrom-Json
    if ($dryRunApply.actionId -eq 'performance.applyProfile' -and $dryRunApply.dryRun -eq $true -and $dryRunApply.status -eq 'preview') {
        Add-Pass "Apply without -ConfirmApply returned dry-run preview"
    } else {
        Add-Failure "Apply without -ConfirmApply returned an unexpected envelope"
    }
    if ($null -eq $dryRunApply.backup) {
        Add-Pass "Dry-run apply backup is null"
    } else {
        Add-Failure "Dry-run apply backup should be null"
    }
    if (@($dryRunApply.result.changedItems).Count -eq 0) {
        Add-Pass "Dry-run apply reported zero changed items"
    } else {
        Add-Failure "Dry-run apply reported changed items"
    }
} catch {
    Add-Failure "Dry-run apply failed: $($_.Exception.Message)"
}

try {
    $rollbackPreview = & (Join-Path $PSScriptRoot 'Restore-ProcessProfileBackup.ps1') -BackupPath (Join-Path $repoRoot 'backend\samples\process-profile-backup.sample.json') | ConvertFrom-Json
    if ($rollbackPreview.actionId -eq 'performance.rollbackProfile' -and $rollbackPreview.dryRun -eq $true -and $rollbackPreview.status -eq 'preview') {
        Add-Pass "Rollback preview returned a structured action envelope"
    } else {
        Add-Failure "Rollback preview returned an unexpected envelope"
    }
} catch {
    Add-Failure "Rollback preview failed: $($_.Exception.Message)"
}

Add-Pass "Validation did not invoke -ConfirmApply for apply or rollback scripts"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "PASS Process profile backend validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Process profile backend validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
