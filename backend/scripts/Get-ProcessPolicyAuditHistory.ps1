param(
    [string]$StateRoot = '',
    [string]$Process = '',
    [string]$Action = '',
    [string]$Since = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicyRules.Common.ps1')

try {
    $rows = @(Read-RooProcessPolicyAuditRows $StateRoot)
    $sinceUtc = $null
    if (-not [string]::IsNullOrWhiteSpace($Since)) {
        $sinceUtc = ([DateTime]::Parse($Since)).ToUniversalTime()
    }

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        if (-not [string]::IsNullOrWhiteSpace($Action) -and [string](Get-RooPropertyValue $row 'action' '') -ne $Action) {
            continue
        }
        if ($sinceUtc) {
            $rowTime = ([DateTime]::Parse([string](Get-RooPropertyValue $row 'timestampUtc' '1970-01-01T00:00:00Z'))).ToUniversalTime()
            if ($rowTime -lt $sinceUtc) { continue }
        }
        if (-not [string]::IsNullOrWhiteSpace($Process)) {
            $target = Get-RooPropertyValue $row 'targetProcess' $null
            $identity = [string](Get-RooPropertyValue $row 'targetProcessIdentity' '')
            $processName = [string](Get-RooPropertyValue $target 'processName' '')
            $processId = [string](Get-RooPropertyValue $target 'processId' '')
            $path = [string](Get-RooPropertyValue $target 'executablePath' '')
            if ($identity -notlike "*$Process*" -and $processName -notlike "*$Process*" -and $processId -ne $Process -and $path -notlike "*$Process*") {
                continue
            }
        }
        $filtered.Add($row) | Out-Null
    }

    $actionCounts = @{}
    $outcomeCounts = @{}
    $processIdentities = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in @($filtered.ToArray())) {
        $actionName = [string](Get-RooPropertyValue $row 'action' 'unknown')
        $outcome = [string](Get-RooPropertyValue $row 'outcome' 'unknown')
        if (-not $actionCounts.ContainsKey($actionName)) { $actionCounts[$actionName] = 0 }
        if (-not $outcomeCounts.ContainsKey($outcome)) { $outcomeCounts[$outcome] = 0 }
        $actionCounts[$actionName] = [int]$actionCounts[$actionName] + 1
        $outcomeCounts[$outcome] = [int]$outcomeCounts[$outcome] + 1
        $identity = [string](Get-RooPropertyValue $row 'targetProcessIdentity' '')
        if (-not [string]::IsNullOrWhiteSpace($identity)) { $processIdentities.Add($identity) | Out-Null }
    }

    $actionSummary = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($actionCounts.Keys | Sort-Object)) {
        $actionSummary.Add([pscustomobject]@{ action = [string]$key; count = [int]$actionCounts[$key] }) | Out-Null
    }
    $outcomeSummary = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($outcomeCounts.Keys | Sort-Object)) {
        $outcomeSummary.Add([pscustomobject]@{ outcome = [string]$key; count = [int]$outcomeCounts[$key] }) | Out-Null
    }

    $result = [pscustomobject]@{
        actionId = 'performance.policy.auditHistory'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        status = 'completed'
        stateRoot = Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot
        auditPath = Get-RooProcessPolicyAuditPath $StateRoot
        filters = [pscustomobject]@{
            process = if ([string]::IsNullOrWhiteSpace($Process)) { $null } else { $Process }
            action = if ([string]::IsNullOrWhiteSpace($Action)) { $null } else { $Action }
            since = if ([string]::IsNullOrWhiteSpace($Since)) { $null } else { $Since }
        }
        summary = [pscustomobject]@{
            rowCount = $filtered.Count
            totalRowCount = $rows.Count
            processIdentityCount = $processIdentities.Count
            actions = @($actionSummary.ToArray())
            outcomes = @($outcomeSummary.ToArray())
        }
        auditRows = @($filtered.ToArray())
        warnings = @()
        errors = @()
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.policy.auditHistory'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        status = 'failed'
        stateRoot = Resolve-RooProcessPolicyRuntimeStateRoot $StateRoot
        auditPath = Get-RooProcessPolicyAuditPath $StateRoot
        filters = [pscustomobject]@{
            process = if ([string]::IsNullOrWhiteSpace($Process)) { $null } else { $Process }
            action = if ([string]::IsNullOrWhiteSpace($Action)) { $null } else { $Action }
            since = if ([string]::IsNullOrWhiteSpace($Since)) { $null } else { $Since }
        }
        summary = [pscustomobject]@{
            rowCount = 0
            totalRowCount = 0
            processIdentityCount = 0
            actions = @()
            outcomes = @()
        }
        auditRows = @()
        warnings = @()
        errors = @((New-RooIssue 'PROCESS_POLICY_AUDIT_HISTORY_FAILED' $_.Exception.Message 'error' 'performance.policy' $StateRoot $true 'Check the runtime state root and filter values.' $null))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
