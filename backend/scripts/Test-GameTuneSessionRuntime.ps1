$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
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

function Test-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $RelativePath"
    } else {
        Add-Failure "Required file missing: $RelativePath"
    }
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

function Test-PowerShellParser {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) {
        Add-Pass "PowerShell parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } else {
        $message = ($errors | ForEach-Object { $_.Message }) -join '; '
        Add-Failure "PowerShell parse failed: $Path :: $message"
    }
}

$requiredFiles = @(
    'backend\scripts\GameTuneSession.Common.ps1',
    'backend\scripts\Start-GameTuneSession.ps1',
    'backend\scripts\Stop-GameTuneSession.ps1',
    'backend\scripts\Get-GameTuneSessionStatus.ps1',
    'backend\samples\game-tune-session-dry-run.sample.json',
    'backend\samples\game-tune-session-confirmed.sample.json',
    'backend\samples\game-tune-session-status.sample.json',
    'backend\samples\game-tune-session-restore-preview.sample.json',
    'backend\samples\game-tune-session-restore-result.sample.json'
)
foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

$jsonRoots = @(
    (Join-Path $repoRoot 'backend\contracts'),
    (Join-Path $repoRoot 'backend\samples'),
    (Join-Path $repoRoot 'backend\profiles'),
    (Join-Path $repoRoot 'modules')
)
foreach ($root in $jsonRoots) {
    if (Test-Path -LiteralPath $root) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File) {
            Test-JsonFile $file.FullName
        }
    }
}

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'backend\scripts') -Filter '*.ps1' -File) {
    Test-PowerShellParser $file.FullName
}

try {
    $dryRunStateRoot = Join-Path (Join-Path $repoRoot 'backend\state') ("game-tune-dry-run-validation-$([guid]::NewGuid().ToString('N'))")
    $dryRun = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') `
        -ProfilePath (Join-Path $repoRoot 'backend\profiles\game-session.profile.json') `
        -PollIntervalSeconds 1 `
        -MaxDurationSeconds 1 `
        -StateRoot $dryRunStateRoot | ConvertFrom-Json

    if ($dryRun.actionId -eq 'performance.gameTune.startSession' -and $dryRun.dryRun -eq $true -and $dryRun.status -eq 'completed') {
        Add-Pass 'Dry-run Game Tune session returned a completed session envelope'
    } else {
        Add-Failure 'Dry-run Game Tune session returned an unexpected envelope'
    }
    if (@($dryRun.changedItems).Count -eq 0 -and $null -eq $dryRun.backupManifestPath -and $dryRun.restorable -eq $false) {
        Add-Pass 'Dry-run Game Tune session reported no changed items and no backup'
    } else {
        Add-Failure 'Dry-run Game Tune session reported changes or backup state'
    }
    if (-not (Test-Path -LiteralPath $dryRunStateRoot)) {
        Add-Pass 'Dry-run Game Tune session left no state root behind'
    } else {
        Add-Failure "Dry-run Game Tune session created state root: $dryRunStateRoot"
    }
} catch {
    Add-Failure "Dry-run Game Tune session execution failed: $($_.Exception.Message)"
}

try {
    $restorePreview = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') `
        -BackupPath (Join-Path $repoRoot 'backend\samples\process-profile-backup.sample.json') | ConvertFrom-Json
    if ($restorePreview.actionId -eq 'performance.gameTune.stopSession' -and $restorePreview.dryRun -eq $true -and $restorePreview.status -eq 'preview') {
        Add-Pass 'Game Tune restore preview returned a structured preview envelope'
    } else {
        Add-Failure 'Game Tune restore preview returned an unexpected envelope'
    }
    if (@($restorePreview.changedItems).Count -eq 0 -and @($restorePreview.restoredItems).Count -eq 0) {
        Add-Pass 'Game Tune restore preview did not apply priority changes'
    } else {
        Add-Failure 'Game Tune restore preview reported applied changes'
    }
} catch {
    Add-Failure "Game Tune restore preview failed: $($_.Exception.Message)"
}

try {
    $status = & (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1') `
        -StateRoot (Join-Path $repoRoot 'backend\state\missing-game-tune-validation') | ConvertFrom-Json
    if ($status.actionId -eq 'performance.gameTune.sessionStatus' -and $status.status -eq 'notFound') {
        Add-Pass 'Game Tune status reports notFound cleanly when no session exists'
    } else {
        Add-Failure 'Game Tune status missing-session result had an unexpected shape'
    }
} catch {
    Add-Failure "Game Tune status notFound check failed: $($_.Exception.Message)"
}

try {
    $liveRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-game-tune-live-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
    $probeExe = Join-Path $liveRoot 'RooTuneProbe.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $probeExe -Force
    $probe = $null
    try {
        $probe = Start-Process -FilePath $probeExe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 800
        $before = Get-RooProcessControlState $probe.Id $null
        $targetAffinity = if (($before.affinityMask -band 1) -eq 1 -and [int64]$before.affinityMask -ne 1) { 1 } elseif (($before.affinityMask -band 2) -eq 2) { 2 } else { $before.affinityMask }
        $profilePath = Join-Path $liveRoot 'live-profile.json'
        $stateRoot = Join-Path $liveRoot 'state'
        $profile = [pscustomobject]@{
            schemaVersion = 1
            productName = 'Roo Industries Optimization Suite'
            profileId = 'live-process-control-validation'
            name = 'Live Process Control Validation'
            profileKind = 'process-controls'
            risk = 'medium'
            protectedCatalogPath = (Join-Path $repoRoot 'backend\profiles\protected-processes.json')
            foregroundGame = [pscustomobject]@{
                ruleId = 'live-probe-controls'
                processNames = @('RooTuneProbe.exe')
                priorityClass = 'AboveNormal'
                affinityMask = [int64]$targetAffinity
                ioPriority = 'Low'
                gpuPriority = 'AboveNormal'
                reason = 'Validate live process controls against a disposable probe process.'
                reasonCodes = @('LIVE_VALIDATION')
            }
            targetGames = @()
            protectedCompanions = @()
            protectedPreviewProcessNames = @()
            safeCandidates = @()
            rules = @()
            rollbackPolicy = [pscustomobject]@{
                supported = $true
                scope = 'process-controls'
                stateRoot = $stateRoot
                restoreOriginalPriorityClass = $true
            }
            safety = [pscustomobject]@{
                confirmedApplyChanges = @('PriorityClass','Affinity','IoPriority','GpuPriority')
                continuousEnforcement = $true
                runtimeService = $false
            }
        }
        ($profile | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $profilePath -Encoding UTF8

        $start = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') `
            -ProfilePath $profilePath `
            -TargetGameProcessName 'RooTuneProbe.exe' `
            -PollIntervalSeconds 1 `
            -MaxDurationSeconds 1 `
            -StateRoot $stateRoot `
            -ConfirmApply | ConvertFrom-Json
        $afterApply = Get-RooProcessControlState $probe.Id $null

        if ($start.dryRun -eq $false -and $start.status -eq 'completed' -and @($start.changedItems).Count -ge 1) {
            Add-Pass 'Live Game Tune session applied process controls to disposable probe'
        } else {
            Add-Failure 'Live Game Tune session did not report a confirmed changed probe'
        }
        if ($afterApply.priorityClass -eq 'AboveNormal') {
            Add-Pass 'Live probe priority changed to AboveNormal'
        } else {
            Add-Failure "Live probe priority did not change to AboveNormal: $($afterApply.priorityClass)"
        }
        if ([int64]$afterApply.affinityMask -eq [int64]$targetAffinity) {
            Add-Pass "Live probe affinity changed to mask $targetAffinity"
        } else {
            Add-Failure "Live probe affinity did not change to mask ${targetAffinity}: $($afterApply.affinityMask)"
        }
        if ($afterApply.ioPriority -eq 'Low') {
            Add-Pass 'Live probe I/O priority changed to Low'
        } else {
            Add-Failure "Live probe I/O priority did not change to Low: $($afterApply.ioPriority)"
        }
        if ($afterApply.gpuPriority -eq 'AboveNormal') {
            Add-Pass 'Live probe GPU priority changed to AboveNormal'
        } else {
            Add-Failure "Live probe GPU priority did not change to AboveNormal: $($afterApply.gpuPriority)"
        }

        $statusAfterStart = & (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1') -SessionPath $start.sessionPath | ConvertFrom-Json
        if ($statusAfterStart.status -eq 'restorable' -and $statusAfterStart.restorable -eq $true) {
            Add-Pass 'Live Game Tune session status is restorable after confirmed apply'
        } else {
            Add-Failure 'Live Game Tune session status did not become restorable'
        }

        $restorePreview = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $start.sessionPath | ConvertFrom-Json
        $afterPreview = Get-RooProcessControlState $probe.Id $null
        if ($restorePreview.dryRun -eq $true -and $afterPreview.priorityClass -eq 'AboveNormal' -and $afterPreview.ioPriority -eq 'Low' -and $afterPreview.gpuPriority -eq 'AboveNormal') {
            Add-Pass 'Live Game Tune restore preview did not change the probe'
        } else {
            Add-Failure 'Live Game Tune restore preview changed the probe unexpectedly'
        }

        $restore = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $start.sessionPath -ConfirmApply | ConvertFrom-Json
        $afterRestore = Get-RooProcessControlState $probe.Id $null
        if ($restore.dryRun -eq $false -and $restore.status -eq 'completed' -and @($restore.restoredItems).Count -ge 1) {
            Add-Pass 'Live Game Tune restore confirmed against disposable probe'
        } else {
            Add-Failure 'Live Game Tune restore did not report a confirmed restore'
        }
        if ($afterRestore.priorityClass -eq $before.priorityClass -and [int64]$afterRestore.affinityMask -eq [int64]$before.affinityMask -and $afterRestore.ioPriority -eq $before.ioPriority -and $afterRestore.gpuPriority -eq $before.gpuPriority) {
            Add-Pass 'Live probe process controls restored to original state'
        } else {
            Add-Failure "Live probe restore mismatch: priority $($afterRestore.priorityClass)/$($before.priorityClass), affinity $($afterRestore.affinityMask)/$($before.affinityMask), I/O $($afterRestore.ioPriority)/$($before.ioPriority), GPU $($afterRestore.gpuPriority)/$($before.gpuPriority)"
        }
    } finally {
        if ($probe) { Stop-RooValidationProcess $probe }
        $tempRoot = [System.IO.Path]::GetTempPath()
        $fullLiveRoot = [System.IO.Path]::GetFullPath($liveRoot)
        if ($fullLiveRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullLiveRoot)) {
            Remove-Item -LiteralPath $fullLiveRoot -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $fullLiveRoot) { throw "Game Tune validation left its fixture directory: $fullLiveRoot" }
        Add-Pass 'Game Tune probe exited and its fixture directory was removed'
    }
} catch {
    Add-Failure "Live Game Tune process-control validation failed: $($_.Exception.Message)"
}

try {
    $runtimeScriptFiles = @(
        (Join-Path $PSScriptRoot 'GameTuneSession.Common.ps1'),
        (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1'),
        (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1'),
        (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1')
    )
    $forbiddenPattern = '(?i)\b(Set-ItemProperty|New-ItemProperty|Remove-Item|Remove-ItemProperty|Clear-Item|Stop-Service|Start-Service|Set-Service|sc\.exe|pnputil|Disable-PnpDevice|Enable-PnpDevice|Uninstall-Package|msiexec|winget\s+uninstall|Stop-Process|taskkill|reg\.exe|Clear-Standby|EmptyWorkingSet)\b'
    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($scriptPath in $runtimeScriptFiles) {
        $content = Get-Content -LiteralPath $scriptPath -Raw
        if ($content -match $forbiddenPattern) {
            $matches.Add((Split-Path $scriptPath -Leaf)) | Out-Null
        }
    }
    if ($matches.Count -eq 0) {
        Add-Pass 'Game Tune runtime scripts do not call registry, service, driver, uninstall, delete, process-kill, or standby-memory actions'
    } else {
        Add-Failure "Forbidden action pattern found in Game Tune runtime scripts: $($matches -join ', ')"
    }
} catch {
    Add-Failure "Forbidden action scan failed: $($_.Exception.Message)"
}

Add-Pass 'Validation invokes -ConfirmApply only against a disposable local probe process'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Game Tune session runtime validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Game Tune session runtime validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
