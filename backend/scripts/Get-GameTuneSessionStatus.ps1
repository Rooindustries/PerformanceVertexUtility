param(
    [string]$SessionId = '',
    [string]$SessionPath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameTuneSession.Common.ps1')

try {
    $resolvedStateRoot = Resolve-RooGameTuneStateRoot $StateRoot
    $resolvedSessionPath = Resolve-RooGameTuneSessionFile $SessionId $SessionPath $StateRoot
    if ([string]::IsNullOrWhiteSpace($resolvedSessionPath) -or -not (Test-Path -LiteralPath $resolvedSessionPath)) {
        $notFound = [pscustomobject]@{
            actionId = 'performance.gameTune.sessionStatus'
            schemaVersion = 1
            productName = $script:RooProcessProductName
            capturedAtUtc = Get-RooUtcStamp
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
                pollCount = 0
            }
            latestLogs = @()
            warnings = @((New-RooIssue 'GAME_TUNE_SESSION_NOT_FOUND' 'No Game Tune session state was found.' 'warning' 'performance.gameTune' $resolvedStateRoot $false 'Start a confirmed session or provide a session path.' $null))
            errors = @()
        }
        Write-RooJsonOutput $notFound $OutputPath
        exit 0
    }

    $session = Read-RooJsonFile $resolvedSessionPath
    $sessionDirectory = Split-Path $resolvedSessionPath -Parent
    $rawStatus = [string](Get-RooPropertyValue $session 'sessionStatus' (Get-RooPropertyValue $session 'status' 'completed'))
    $isRunning = $rawStatus -eq 'running'
    $isFailed = $rawStatus -eq 'failed'
    $isRestorable = [bool](Get-RooPropertyValue $session 'restorable' $false)
    $status = if ($isRunning) { 'active' } elseif ($isFailed) { 'failed' } elseif ($isRestorable) { 'restorable' } else { 'completed' }

    $latestLogs = New-Object System.Collections.Generic.List[object]
    $logPath = Join-Path $sessionDirectory 'events.jsonl'
    if (Test-Path -LiteralPath $logPath) {
        foreach ($line in @(Get-Content -LiteralPath $logPath -Tail 20)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $latestLogs.Add(($line | ConvertFrom-Json)) | Out-Null } catch { }
        }
    } else {
        foreach ($log in @(Get-RooPropertyArray $session 'logs')) { $latestLogs.Add($log) | Out-Null }
    }

    $result = [pscustomobject]@{
        actionId = 'performance.gameTune.sessionStatus'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        status = $status
        sessionStatus = $status
        rawSessionStatus = $rawStatus
        sessionId = [string](Get-RooPropertyValue $session 'sessionId' '')
        profileId = [string](Get-RooPropertyValue $session 'profileId' '')
        profilePath = Get-RooPropertyValue $session 'profilePath' $null
        targetGameProcessName = Get-RooPropertyValue $session 'targetGameProcessName' $null
        dryRun = [bool](Get-RooPropertyValue $session 'dryRun' $false)
        stateRoot = $resolvedStateRoot
        sessionPath = $resolvedSessionPath
        backupManifestPath = Get-RooPropertyValue $session 'backupManifestPath' $null
        restorable = $isRestorable
        active = ($status -eq 'active')
        completed = ($status -eq 'completed')
        failed = ($status -eq 'failed')
        startedAtUtc = Get-RooPropertyValue $session 'startedAtUtc' $null
        completedAtUtc = Get-RooPropertyValue $session 'completedAtUtc' $null
        summary = [pscustomobject]@{
            changedItemCount = @(Get-RooPropertyArray $session 'changedItems').Count
            skippedItemCount = @(Get-RooPropertyArray $session 'skippedItems').Count
            restoredItemCount = @(Get-RooPropertyArray $session 'restoredItems').Count
            pollCount = [int](Get-RooPropertyValue $session 'pollCount' 0)
        }
        changedItems = @(Get-RooPropertyArray $session 'changedItems')
        skippedItems = @(Get-RooPropertyArray $session 'skippedItems')
        restoredItems = @(Get-RooPropertyArray $session 'restoredItems')
        latestLogs = @($latestLogs.ToArray())
        warnings = @(Get-RooPropertyArray $session 'warnings')
        errors = @(Get-RooPropertyArray $session 'errors')
    }

    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.gameTune.sessionStatus'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
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
            pollCount = 0
        }
        latestLogs = @()
        warnings = @()
        errors = @((New-RooIssue 'GAME_TUNE_STATUS_FAILED' $_.Exception.Message 'error' 'performance.gameTune' $SessionPath $true 'Check the session state path and retry.' $null))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
