param(
    [string]$SessionId = '',
    [string]$SessionPath = '',
    [string]$StateRoot = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')

try {
    $resolvedStateRoot = Resolve-RooIndustriesProcessPolicyStateRoot $StateRoot
    $resolvedSessionPath = Resolve-RooIndustriesProcessPolicySessionFile $SessionId $SessionPath $StateRoot
    if ([string]::IsNullOrWhiteSpace($resolvedSessionPath) -or -not (Test-Path -LiteralPath $resolvedSessionPath)) {
        $notFound = [pscustomobject]@{
            actionId = 'performance.policy.sessionStatus'
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
                activeApplicationCount = 0
                pollCount = 0
            }
            changedItems = @()
            skippedItems = @()
            restoredItems = @()
            activeApplications = @()
            latestLogs = @()
            warnings = @((New-RooIndustriesIssue 'PROCESS_POLICY_SESSION_NOT_FOUND' 'No persistent policy session state was found.' 'warning' 'performance.policy' $resolvedStateRoot $false 'Start a confirmed session or provide a session path.' $null))
            errors = @()
        }
        Write-RooIndustriesJsonOutput $notFound $OutputPath
        exit 0
    }

    $session = Read-RooIndustriesJsonFile $resolvedSessionPath
    $sessionDirectory = Split-Path $resolvedSessionPath -Parent
    $rawStatus = [string](Get-RooIndustriesPropertyValue $session 'sessionStatus' (Get-RooIndustriesPropertyValue $session 'status' 'completed'))
    $isRunning = $rawStatus -eq 'running'
    $isFailed = $rawStatus -eq 'failed'
    $isRestorable = [bool](Get-RooIndustriesPropertyValue $session 'restorable' $false)
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
        actionId = 'performance.policy.sessionStatus'
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
        startedAtUtc = Get-RooIndustriesPropertyValue $session 'startedAtUtc' $null
        completedAtUtc = Get-RooIndustriesPropertyValue $session 'completedAtUtc' $null
        summary = [pscustomobject]@{
            changedItemCount = @(Get-RooIndustriesPropertyArray $session 'changedItems').Count
            skippedItemCount = @(Get-RooIndustriesPropertyArray $session 'skippedItems').Count
            restoredItemCount = @(Get-RooIndustriesPropertyArray $session 'restoredItems').Count
            activeApplicationCount = @(Get-RooIndustriesPropertyArray $session 'activeApplications').Count
            pollCount = [int](Get-RooIndustriesPropertyValue $session 'pollCount' 0)
        }
        changedItems = @(Get-RooIndustriesPropertyArray $session 'changedItems')
        skippedItems = @(Get-RooIndustriesPropertyArray $session 'skippedItems')
        restoredItems = @(Get-RooIndustriesPropertyArray $session 'restoredItems')
        activeApplications = @(Get-RooIndustriesPropertyArray $session 'activeApplications')
        latestLogs = @($latestLogs.ToArray())
        warnings = @(Get-RooIndustriesPropertyArray $session 'warnings')
        errors = @(Get-RooIndustriesPropertyArray $session 'errors')
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.policy.sessionStatus'
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
            activeApplicationCount = 0
            pollCount = 0
        }
        changedItems = @()
        skippedItems = @()
        restoredItems = @()
        activeApplications = @()
        latestLogs = @()
        warnings = @()
        errors = @((New-RooIndustriesIssue 'PROCESS_POLICY_STATUS_FAILED' $_.Exception.Message 'error' 'performance.policy' $SessionPath $true 'Check the persistent policy session state path and retry.' $null))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
