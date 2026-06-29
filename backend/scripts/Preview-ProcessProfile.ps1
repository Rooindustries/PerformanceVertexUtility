param(
    [string]$ProfilePath = '',
    [string]$TargetGameProcessName = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Get-ProfileSafeRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooPropertyArray $Profile 'safeCandidates')) {
        if ([string](Get-RooPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function Get-ProtectedReasonById {
    param(
        [object]$ProtectedCatalog,
        [string]$ItemId
    )
    foreach ($item in @(Get-RooPropertyArray $ProtectedCatalog 'protectedProcesses')) {
        if ([string](Get-RooPropertyValue $item 'itemId' '') -eq $ItemId) {
            return [string](Get-RooPropertyValue $item 'reason' 'Protected process.')
        }
    }
    return 'Protected process.'
}

function Get-CompanionReasonById {
    param(
        [object]$Profile,
        [string]$ItemId
    )
    foreach ($item in @(Get-RooPropertyArray $Profile 'protectedCompanions')) {
        if ([string](Get-RooPropertyValue $item 'itemId' '') -eq $ItemId) {
            return [string](Get-RooPropertyValue $item 'reason' 'Protected companion process.')
        }
    }
    return 'Protected companion process.'
}

function New-ProcessPreviewEntry {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog
    )

    $classification = [string](Get-RooPropertyValue $Process 'classification' 'unknown')
    $ruleId = [string](Get-RooPropertyValue $Process 'matchedRuleId' '')
    $reason = 'No process priority change proposed.'
    $proposedAction = 'noChange'
    $proposedPriority = Get-RooPropertyValue $Process 'priorityClass' $null
    $rollbackSupported = $false
    $risk = [string](Get-RooPropertyValue $Process 'risk' 'low')
    $blocked = [bool](Get-RooPropertyValue $Process 'blocked' $false)
    $protected = [bool](Get-RooPropertyValue $Process 'protected' $false)
    $confidence = 'medium'

    if ($classification -eq 'gameTarget') {
        $foregroundGame = Get-RooPropertyValue $Profile 'foregroundGame' $null
        $ruleId = [string](Get-RooPropertyValue $foregroundGame 'ruleId' 'boost-foreground-game')
        $proposedAction = 'setPriority'
        $proposedPriority = [string](Get-RooPropertyValue $foregroundGame 'priorityClass' 'AboveNormal')
        $reason = [string](Get-RooPropertyValue $foregroundGame 'reason' 'Foreground game boost for frame-time stability.')
        $rollbackSupported = $true
        $risk = 'medium'
    } elseif ($classification -eq 'demotionCandidate') {
        $rule = Get-RooRuleById $Profile $ruleId
        $action = Get-RooPropertyValue $rule 'action' $null
        $proposedAction = 'setPriority'
        $proposedPriority = [string](Get-RooPropertyValue $action 'priorityClass' 'BelowNormal')
        $reason = [string](Get-RooPropertyValue $action 'reason' 'Background priority demotion candidate.')
        $rollbackSupported = $true
        $risk = [string](Get-RooPropertyValue $rule 'risk' 'low')
    } elseif ($classification -eq 'protectedCompanion') {
        $reason = Get-CompanionReasonById $Profile ([string](Get-RooPropertyValue $Process 'matchedProfileItemId' ''))
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        $confidence = 'high'
    } elseif ($classification -eq 'protected') {
        $reason = Get-ProtectedReasonById $ProtectedCatalog ([string](Get-RooPropertyValue $Process 'matchedProtectedItemId' ''))
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        $confidence = 'high'
    } elseif ($classification -eq 'safeCandidate') {
        $safeRule = Get-ProfileSafeRuleById $Profile $ruleId
        $reason = [string](Get-RooPropertyValue $safeRule 'reason' 'Manual-review candidate; no automatic priority change.')
        $risk = [string](Get-RooPropertyValue $safeRule 'risk' 'low')
    }

    $currentPriority = Get-RooPropertyValue $Process 'priorityClass' $null
    if ($proposedAction -eq 'setPriority') {
        if (-not (Test-RooPriorityAllowed $proposedPriority)) {
            $blocked = $true
            $proposedAction = 'noChange'
            $rollbackSupported = $false
            $reason = "Priority class '$proposedPriority' is outside the MVP allow-list."
        } elseif (-not [bool](Get-RooPropertyValue $Process 'canChangePriority' $false)) {
            $blocked = $true
            $proposedAction = 'noChange'
            $rollbackSupported = $false
            $reason = 'Process is not safe to change from this profile pass.'
        } elseif ($null -eq $currentPriority -or [string]::IsNullOrWhiteSpace([string]$currentPriority)) {
            $blocked = $true
            $proposedAction = 'noChange'
            $rollbackSupported = $false
            $reason = 'Current priority class could not be read, so no change is proposed.'
        } elseif ([string]$currentPriority -eq $proposedPriority) {
            $proposedAction = 'noChange'
            $rollbackSupported = $false
            $reason = "Process is already at $proposedPriority priority."
        }
    }

    if ($proposedAction -eq 'noChange') {
        $proposedPriority = $currentPriority
    }

    $processId = [int](Get-RooPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooPropertyValue $Process 'name' '')
    $previewId = (($ruleId, $classification, $processName, $processId) -join '-').ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
    if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = $classification }

    return [pscustomobject]@{
        previewId = $previewId
        type = 'processPriority'
        target = "$processName`:$processId"
        displayName = Get-RooPropertyValue $Process 'displayName' $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Process 'executablePath' $null
        currentPriorityClass = $currentPriority
        proposedPriorityClass = $proposedPriority
        proposedAction = $proposedAction
        ruleId = $ruleId
        reason = $reason
        reasonCodes = @(Get-RooPropertyArray $Process 'reasonCodes')
        classification = $classification
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = $risk
        confidence = $confidence
        protected = $protected
        requiresConfirmation = ($proposedAction -eq 'setPriority')
        rollbackSupported = $rollbackSupported
        currentState = [pscustomobject]@{
            priorityClass = $currentPriority
            workingSetBytes = Get-RooPropertyValue $Process 'workingSetBytes' 0
            privateBytes = Get-RooPropertyValue $Process 'privateBytes' $null
            cpuPercent = Get-RooPropertyValue $Process 'cpuPercent' $null
            classification = $classification
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = $proposedPriority
            reason = $reason
        }
        impact = [pscustomobject]@{
            expectedMemoryEffectBytes = 0
            expectedCpuWakeupEffect = if ($classification -eq 'demotionCandidate') { 'lower' } else { 'neutral' }
            targetMetrics = @('frame-time-stability', '1-percent-low-fps', '0.1-percent-low-fps', 'process-count')
        }
        rollback = if ($rollbackSupported) {
            [pscustomobject]@{
                restorePriorityClass = $currentPriority
                captureOriginalState = $true
            }
        } else {
            $null
        }
    }
}

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\game-session.profile.json'
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath
    $catalogPathValue = [string](Get-RooPropertyValue $profile 'protectedCatalogPath' 'protected-processes.json')
    $protectedCatalogPath = if ([System.IO.Path]::IsPathRooted($catalogPathValue)) {
        $catalogPathValue
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Split-Path $resolvedProfilePath -Parent) $catalogPathValue))
    }
    $protectedCatalog = Read-RooJsonFile $protectedCatalogPath

    $classificationArgs = @{ ProfilePath = $resolvedProfilePath }
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        $classificationArgs['TargetGameProcessName'] = $TargetGameProcessName
    }
    $classification = & (Join-Path $PSScriptRoot 'Get-ProcessClassification.ps1') @classificationArgs | ConvertFrom-Json

    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-RooPropertyArray $classification 'processes')) {
        $className = [string](Get-RooPropertyValue $proc 'classification' 'unknown')
        $include = ([bool](Get-RooPropertyValue $proc 'sessionProfileMatched' $false)) -or ($className -in @('gameTarget', 'demotionCandidate', 'protectedCompanion'))
        if (-not $include) { continue }
        $preview.Add((New-ProcessPreviewEntry $proc $profile $protectedCatalog)) | Out-Null
    }

    $warnings = New-Object System.Collections.Generic.List[object]
    $warnings.Add((New-RooIssue 'PROCESS_PROFILE_PREVIEW_ONLY' 'Preview built without applying process priority changes.' 'info' 'performance.profile' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Run Apply-ProcessProfile.ps1 with -ConfirmApply only after reviewing the preview.' $null)) | Out-Null
    if ($preview.Count -eq 0) {
        $warnings.Add((New-RooIssue 'NO_MATCHING_PROCESSES' 'No running processes matched this profile.' 'warning' 'performance.profile' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Launch the target game or companion apps, then preview again.' $null)) | Out-Null
    }

    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.previewProfile' `
        -DryRun $true `
        -Risk ([string](Get-RooPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status 'preview' `
        -Preview @($preview.ToArray()) `
        -Backup $null `
        -Result $null `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooLog "Preview generated for profile $([string](Get-RooPropertyValue $profile 'profileId' ''))."))

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.previewProfile' `
        -DryRun $true `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIssue 'PROCESS_PROFILE_PREVIEW_FAILED' $_.Exception.Message 'error' 'performance.profile' $ProfilePath $true 'Check the profile path and process inventory script.' $null)) `
        -Logs @((New-RooLog 'Preview failed.' 'error'))
    Write-RooJsonOutput $envelope $OutputPath
    exit 1
}
