param(
    [string]$SessionId = '',
    [string]$SessionPath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessGovernor.Common.ps1')

try {
    $resolvedStateRoot = Resolve-RooIndustriesProcessGovernorStateRoot $StateRoot
    $latestOnly = $false
    $unreadableRuns = @()
    $session = $null
    if ([string]::IsNullOrWhiteSpace($SessionId) -and [string]::IsNullOrWhiteSpace($SessionPath)) {
        # Runs whose files can't be read stay pending and are named, but never block the runs Restore can read.
        $unreadableRuns = @(Get-RooIndustriesProcessGovernorUnreadableSessions $resolvedStateRoot)
        $resolvedSessionPath = Get-RooIndustriesProcessGovernorHeldSession $resolvedStateRoot
        if ($null -eq $resolvedSessionPath) {
            $resolvedSessionPath = Get-RooIndustriesProcessGovernorLatestSessionFile $resolvedStateRoot
            $latestOnly = $true
            if ($resolvedSessionPath -and (Test-Path -LiteralPath $resolvedSessionPath)) {
                try { $session = Read-RooIndustriesProcessGovernorSession $resolvedSessionPath } catch { $resolvedSessionPath = $null }
            }
        }
    } else {
        $resolvedSessionPath = Resolve-RooIndustriesProcessGovernorSessionFile $SessionId $SessionPath $StateRoot
    }
    if ([string]::IsNullOrWhiteSpace($resolvedSessionPath) -or -not (Test-Path -LiteralPath $resolvedSessionPath)) {
        $notFound = [pscustomobject]@{
            actionId = 'performance.governor.sessionStatus'
            schemaVersion = 1
            productName = $script:RooIndustriesProcessProductName
            capturedAtUtc = Get-RooIndustriesUtcStamp
            status = 'notFound'
            sessionStatus = 'notFound'
            sessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId }
            stateRoot = $resolvedStateRoot
            sessionPath = $resolvedSessionPath
            restorable = $false
            active = $false
            completed = $false
            failed = $false
            backupManifestPath = $null
            summary = [pscustomobject]@{
                changedItemCount = 0
                skippedItemCount = 0
                restoredItemCount = 0
                activeRestraintCount = 0
                pollCount = 0
            }
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            activeRestraints = @()
            unreadableRuns = $unreadableRuns
            runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $null -StateRoot $resolvedStateRoot -SessionPath $resolvedSessionPath -BackupManifestPath $null
            latestLogs = @()
            warnings = @((New-RooIndustriesIssue 'PROCESS_GOVERNOR_SESSION_NOT_FOUND' 'No process governor session state was found.' 'warning' 'performance.governor' $resolvedStateRoot $false 'Start a confirmed session or provide a session path.' $null))
            errors = @()
        }
        Write-RooIndustriesJsonOutput $notFound $OutputPath
        exit 0
    }

    if ($null -eq $session) { $session = Read-RooIndustriesProcessGovernorSession $resolvedSessionPath }
    $sessionDirectory = Split-Path $resolvedSessionPath -Parent
    $rawStatus = [string](Get-RooIndustriesPropertyValue $session 'sessionStatus' (Get-RooIndustriesPropertyValue $session 'status' 'completed'))
    $isRestorable = [bool](Get-RooIndustriesPropertyValue $session 'restorable' $false) -and -not $latestOnly
    $worker = Get-RooIndustriesPropertyValue $session 'worker' $null
    $interrupted = $rawStatus -eq 'running' -and $(if ($null -ne $worker) { Test-RooIndustriesProcessGovernorWorkerEnded $worker } else { Test-RooIndustriesProcessGovernorSessionOverdue $session })
    $isRunning = $rawStatus -eq 'running' -and -not $interrupted
    $isFailed = $rawStatus -eq 'failed'
    $status = if ($isRunning) { 'active' } elseif ($isFailed) { 'failed' } elseif ($isRestorable) { 'restorable' } else { 'completed' }

    $latestLogs = New-Object System.Collections.Generic.List[object]
    $logPath = Join-Path $sessionDirectory 'events.jsonl'
    if (Test-Path -LiteralPath $logPath) {
        foreach ($line in @(Get-Content -LiteralPath $logPath -Tail 20)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $latestLogs.Add(($line | ConvertFrom-Json)) | Out-Null } catch { }
        }
    } else {
        foreach ($log in @(Get-RooIndustriesPropertyArray $session 'logs')) { $latestLogs.Add($log) | Out-Null }
    }

    $result = [pscustomobject]@{
        actionId = 'performance.governor.sessionStatus'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        status = $status
        sessionStatus = $status
        rawSessionStatus = $rawStatus
        sessionId = [string](Get-RooIndustriesPropertyValue $session 'sessionId' '')
        profileId = [string](Get-RooIndustriesPropertyValue $session 'profileId' '')
        profilePath = Get-RooIndustriesPropertyValue $session 'profilePath' $null
        dryRun = [bool](Get-RooIndustriesPropertyValue $session 'dryRun' $false)
        stateRoot = $resolvedStateRoot
        sessionPath = $resolvedSessionPath
        backupManifestPath = Get-RooIndustriesPropertyValue $session 'backupManifestPath' $null
        restorable = $isRestorable
        active = ($status -eq 'active')
        completed = ($status -eq 'completed')
        failed = ($status -eq 'failed')
        interrupted = $interrupted
        startedAtUtc = Get-RooIndustriesPropertyValue $session 'startedAtUtc' $null
        completedAtUtc = Get-RooIndustriesPropertyValue $session 'completedAtUtc' $null
        summary = [pscustomobject]@{
            changedItemCount = @(Get-RooIndustriesPropertyArray $session 'changedItems').Count
            skippedItemCount = @(Get-RooIndustriesPropertyArray $session 'skippedItems').Count
            restoredItemCount = @(Get-RooIndustriesPropertyArray $session 'restoredItems').Count
            activeRestraintCount = @(Get-RooIndustriesPropertyArray $session 'activeRestraints').Count
            pollCount = [int](Get-RooIndustriesPropertyValue $session 'pollCount' 0)
        }
        changedItems = @(Get-RooIndustriesPropertyArray $session 'changedItems')
        skippedItems = @(Get-RooIndustriesPropertyArray $session 'skippedItems')
        restoredItems = @(Get-RooIndustriesPropertyArray $session 'restoredItems')
        activeRestraints = @(Get-RooIndustriesPropertyArray $session 'activeRestraints')
        unreadableRuns = $unreadableRuns
        runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $session -StateRoot $resolvedStateRoot -SessionPath $resolvedSessionPath -BackupManifestPath (Get-RooIndustriesPropertyValue $session 'backupManifestPath' $null)
        latestLogs = @($latestLogs.ToArray())
        warnings = @(Get-RooIndustriesPropertyArray $session 'warnings')
        errors = @(Get-RooIndustriesPropertyArray $session 'errors')
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.governor.sessionStatus'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        status = 'failed'
        sessionStatus = 'failed'
        sessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId }
        stateRoot = $StateRoot
        sessionPath = $SessionPath
        restorable = $false
        active = $false
        completed = $false
        failed = $true
        backupManifestPath = $null
        summary = [pscustomobject]@{
            changedItemCount = 0
            skippedItemCount = 0
            restoredItemCount = 0
            activeRestraintCount = 0
            pollCount = 0
        }
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        activeRestraints = @()
        runtimeEvidence = New-RooIndustriesProcessGovernorRuntimeEvidence -Session $null -StateRoot $StateRoot -SessionPath $SessionPath -BackupManifestPath $null
        latestLogs = @()
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_GOVERNOR_STATUS_FAILED' $_.Exception.Message 'error' 'performance.governor' $SessionPath $true 'Check the process governor session state path and retry.' $null))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
