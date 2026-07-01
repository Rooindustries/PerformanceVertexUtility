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
    $reason = 'No process control change proposed.'
    $proposedAction = 'noChange'
    $proposedPriority = Get-RooPropertyValue $Process 'priorityClass' $null
    $proposedAffinityMask = $null
    $proposedIoPriority = $null
    $proposedGpuPriority = $null
    $rollbackSupported = $false
    $risk = [string](Get-RooPropertyValue $Process 'risk' 'low')
    $blocked = [bool](Get-RooPropertyValue $Process 'blocked' $false)
    $protected = [bool](Get-RooPropertyValue $Process 'protected' $false)
    $confidence = 'medium'
    $actionSource = $null

    if ($classification -eq 'gameTarget') {
        $foregroundGame = Get-RooPropertyValue $Profile 'foregroundGame' $null
        $ruleId = [string](Get-RooPropertyValue $foregroundGame 'ruleId' 'boost-foreground-game')
        $actionSource = $foregroundGame
        $proposedPriority = [string](Get-RooPropertyValue $foregroundGame 'priorityClass' 'AboveNormal')
        $reason = [string](Get-RooPropertyValue $foregroundGame 'reason' 'Foreground game boost for frame-time stability.')
        $rollbackSupported = $true
        $risk = 'medium'
    } elseif ($classification -eq 'demotionCandidate') {
        $rule = Get-RooRuleById $Profile $ruleId
        $action = Get-RooPropertyValue $rule 'action' $null
        $actionSource = $action
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

    if ($actionSource) {
        $proposedAffinityMask = Get-RooPropertyValue $actionSource 'affinityMask' (Get-RooPropertyValue $actionSource 'processorAffinityMask' $null)
        $proposedIoPriority = Get-RooPropertyValue $actionSource 'ioPriority' $null
        $proposedGpuPriority = Get-RooPropertyValue $actionSource 'gpuPriority' $null
    }

    $processId = [int](Get-RooPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooPropertyValue $Process 'name' '')
    $currentControls = Get-RooProcessControlState $processId (Get-RooPropertyValue $Process 'priorityClass' $null)
    $currentPriority = $currentControls.priorityClass
    $currentAffinityMask = $currentControls.affinityMask
    $currentIoPriority = $currentControls.ioPriority
    $currentGpuPriority = $currentControls.gpuPriority
    $controlChanges = New-Object System.Collections.Generic.List[object]
    $canChange = [bool](Get-RooPropertyValue $Process 'canChangePriority' $false)

    if ($actionSource -and -not $protected -and -not $blocked -and $canChange) {
        if (-not [string]::IsNullOrWhiteSpace([string]$proposedPriority)) {
            if (-not (Test-RooPriorityAllowed $proposedPriority)) {
                $reason = "Priority class '$proposedPriority' is outside the allow-list."
            } elseif ($null -eq $currentPriority -or [string]::IsNullOrWhiteSpace([string]$currentPriority)) {
                $reason = 'Current priority class could not be read, so no priority change is proposed.'
            } elseif ([string]$currentPriority -ne [string]$proposedPriority) {
                $controlChanges.Add((New-RooControlChange 'priorityClass' $currentPriority $proposedPriority 'setPriority' $reason)) | Out-Null
            }
        }

        if ($null -ne $proposedAffinityMask) {
            if (-not (Test-RooAffinityMaskAllowed $proposedAffinityMask)) {
                $reason = "Affinity mask '$proposedAffinityMask' is invalid."
            } elseif ($null -eq $currentAffinityMask) {
                $reason = 'Current CPU affinity could not be read, so no affinity change is proposed.'
            } elseif ([int64]$currentAffinityMask -ne [int64]$proposedAffinityMask) {
                $controlChanges.Add((New-RooControlChange 'affinityMask' $currentAffinityMask ([int64]$proposedAffinityMask) 'setAffinity' 'Set process CPU affinity for the selected game profile.')) | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$proposedIoPriority)) {
            if (-not (Test-RooIoPriorityAllowed $proposedIoPriority)) {
                $reason = "I/O priority '$proposedIoPriority' is outside the allow-list."
            } elseif ([string]::IsNullOrWhiteSpace([string]$currentIoPriority)) {
                $reason = 'Current I/O priority could not be read, so no I/O priority change is proposed.'
            } elseif ([string]$currentIoPriority -ne [string]$proposedIoPriority) {
                $controlChanges.Add((New-RooControlChange 'ioPriority' $currentIoPriority $proposedIoPriority 'setIoPriority' 'Set process I/O priority for the selected game profile.')) | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$proposedGpuPriority)) {
            if (-not (Test-RooGpuPriorityAllowed $proposedGpuPriority)) {
                $reason = "GPU priority '$proposedGpuPriority' is outside the allow-list."
            } elseif ([string]::IsNullOrWhiteSpace([string]$currentGpuPriority)) {
                $reason = 'Current GPU priority could not be read, so no GPU priority change is proposed.'
            } elseif ([string]$currentGpuPriority -ne [string]$proposedGpuPriority) {
                $controlChanges.Add((New-RooControlChange 'gpuPriority' $currentGpuPriority $proposedGpuPriority 'setGpuPriority' 'Set process GPU scheduling priority for the selected game profile.')) | Out-Null
            }
        }
    } elseif ($actionSource -and -not $canChange) {
        $blocked = $true
        $rollbackSupported = $false
        $reason = 'Process is not safe to change from this profile pass.'
    }

    if ($controlChanges.Count -gt 0) {
        $proposedAction = if ($controlChanges.Count -eq 1 -and [string](Get-RooPropertyValue $controlChanges[0] 'action' '') -eq 'setPriority') { 'setPriority' } else { 'setProcessControls' }
        $rollbackSupported = $true
        foreach ($change in @($controlChanges.ToArray())) {
            switch ([string](Get-RooPropertyValue $change 'control' '')) {
                'priorityClass' { $proposedPriority = Get-RooPropertyValue $change 'proposedValue' $proposedPriority }
                'affinityMask' { $proposedAffinityMask = Get-RooPropertyValue $change 'proposedValue' $proposedAffinityMask }
                'ioPriority' { $proposedIoPriority = Get-RooPropertyValue $change 'proposedValue' $proposedIoPriority }
                'gpuPriority' { $proposedGpuPriority = Get-RooPropertyValue $change 'proposedValue' $proposedGpuPriority }
            }
        }
    } else {
        $proposedPriority = $currentPriority
        $proposedAffinityMask = $currentAffinityMask
        $proposedIoPriority = $currentIoPriority
        $proposedGpuPriority = $currentGpuPriority
        $rollbackSupported = $false
    }

    $previewId = (($ruleId, $classification, $processName, $processId) -join '-').ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
    if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = $classification }

    return [pscustomobject]@{
        previewId = $previewId
        type = if ($controlChanges.Count -gt 1) { 'processControls' } else { 'processPriority' }
        target = "$processName`:$processId"
        displayName = Get-RooPropertyValue $Process 'displayName' $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooPropertyValue $Process 'executablePath' $null
        currentPriorityClass = $currentPriority
        proposedPriorityClass = $proposedPriority
        currentAffinityMask = $currentAffinityMask
        proposedAffinityMask = $proposedAffinityMask
        currentIoPriority = $currentIoPriority
        proposedIoPriority = $proposedIoPriority
        currentGpuPriority = $currentGpuPriority
        proposedGpuPriority = $proposedGpuPriority
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        ruleId = $ruleId
        reason = $reason
        reasonCodes = @(Get-RooPropertyArray $Process 'reasonCodes')
        classification = $classification
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = $risk
        confidence = $confidence
        protected = $protected
        requiresConfirmation = ($controlChanges.Count -gt 0)
        rollbackSupported = $rollbackSupported
        currentState = [pscustomobject]@{
            priorityClass = $currentPriority
            affinityMask = $currentAffinityMask
            ioPriority = $currentIoPriority
            gpuPriority = $currentGpuPriority
            workingSetBytes = Get-RooPropertyValue $Process 'workingSetBytes' 0
            privateBytes = Get-RooPropertyValue $Process 'privateBytes' $null
            cpuPercent = Get-RooPropertyValue $Process 'cpuPercent' $null
            classification = $classification
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = $proposedPriority
            affinityMask = $proposedAffinityMask
            ioPriority = $proposedIoPriority
            gpuPriority = $proposedGpuPriority
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
                restoreAffinityMask = $currentAffinityMask
                restoreIoPriority = $currentIoPriority
                restoreGpuPriority = $currentGpuPriority
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
