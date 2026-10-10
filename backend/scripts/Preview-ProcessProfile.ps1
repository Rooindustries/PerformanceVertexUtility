param(
    [string]$ProfilePath = '',
    [string]$TargetGameProcessName = '',
    [ValidateSet('lower', 'placement')][string]$Preset = 'lower',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
. (Join-Path $PSScriptRoot 'BackgroundPlacement.Common.ps1')

function Get-ProfileSafeRuleById {
    param(
        [object]$Profile,
        [string]$RuleId
    )
    foreach ($rule in @(Get-RooIndustriesPropertyArray $Profile 'safeCandidates')) {
        if ([string](Get-RooIndustriesPropertyValue $rule 'ruleId' '') -eq $RuleId) { return $rule }
    }
    return $null
}

function Get-ProtectedReasonById {
    param(
        [object]$ProtectedCatalog,
        [string]$ItemId
    )
    foreach ($item in @(Get-RooIndustriesPropertyArray $ProtectedCatalog 'protectedProcesses')) {
        if ([string](Get-RooIndustriesPropertyValue $item 'itemId' '') -eq $ItemId) {
            return [string](Get-RooIndustriesPropertyValue $item 'reason' 'Protected process.')
        }
    }
    return 'Protected process.'
}

function Get-CompanionReasonById {
    param(
        [object]$Profile,
        [string]$ItemId
    )
    foreach ($item in @(Get-RooIndustriesPropertyArray $Profile 'protectedCompanions')) {
        if ([string](Get-RooIndustriesPropertyValue $item 'itemId' '') -eq $ItemId) {
            return [string](Get-RooIndustriesPropertyValue $item 'reason' 'Companion process needs review before changes.')
        }
    }
    return 'Companion process needs review before changes.'
}

function New-ProcessPreviewEntry {
    param(
        [object]$Process,
        [object]$Profile,
        [object]$ProtectedCatalog,
        [object]$Placement
    )

    $classification = [string](Get-RooIndustriesPropertyValue $Process 'classification' 'unknown')
    $ruleId = [string](Get-RooIndustriesPropertyValue $Process 'matchedRuleId' '')
    $reason = 'No process control change proposed.'
    $proposedAction = 'noChange'
    $proposedPriority = Get-RooIndustriesPropertyValue $Process 'priorityClass' $null
    $proposedAffinityMask = $null
    $proposedIoPriority = $null
    $proposedMemoryPriority = $null
    $proposedGpuPriority = $null
    $rollbackSupported = $false
    $risk = [string](Get-RooIndustriesPropertyValue $Process 'risk' 'low')
    $blocked = [bool](Get-RooIndustriesPropertyValue $Process 'blocked' $false)
    $protected = [bool](Get-RooIndustriesPropertyValue $Process 'protected' $false)
    $confidence = 'medium'
    $actionSource = $null

    if ($Preset -eq 'placement') {
        if ($Placement.available -and (Test-RooIndustriesBackgroundPlacementCandidate $Process $Profile $ProtectedCatalog $TargetGameProcessName)) {
            $ruleId = 'place-background-apps'
            $actionSource = [pscustomobject]@{ priorityClass = 'Normal'; ioPriority = 'Normal'; memoryPriority = 5 }
            $proposedPriority = 'Normal'
            $reason = $Placement.label
            $rollbackSupported = $true
        } else {
            $reason = if (-not $Placement.available) { $Placement.reason } else { 'This app is excluded from background placement.' }
        }
    } elseif ($classification -eq 'gameTarget') {
        $foregroundGame = Get-RooIndustriesPropertyValue $Profile 'foregroundGame' $null
        $ruleId = [string](Get-RooIndustriesPropertyValue $foregroundGame 'ruleId' 'boost-foreground-game')
        $actionSource = $foregroundGame
        $proposedPriority = [string](Get-RooIndustriesPropertyValue $foregroundGame 'priorityClass' 'AboveNormal')
        $proposedMemoryPriority = 5
        $reason = [string](Get-RooIndustriesPropertyValue $foregroundGame 'reason' 'Foreground game boost for frame-time stability.')
        $rollbackSupported = $true
        $risk = 'medium'
    } elseif ($classification -eq 'demotionCandidate') {
        $rule = Get-RooIndustriesRuleById $Profile $ruleId
        $action = Get-RooIndustriesPropertyValue $rule 'action' $null
        $actionSource = $action
        $proposedPriority = [string](Get-RooIndustriesPropertyValue $action 'priorityClass' 'BelowNormal')
        $proposedMemoryPriority = 2
        $reason = [string](Get-RooIndustriesPropertyValue $action 'reason' 'Background priority demotion candidate.')
        $rollbackSupported = $true
        $risk = [string](Get-RooIndustriesPropertyValue $rule 'risk' 'low')
    } elseif ($classification -eq 'protectedCompanion') {
        $reason = Get-CompanionReasonById $Profile ([string](Get-RooIndustriesPropertyValue $Process 'matchedProfileItemId' ''))
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        $confidence = 'high'
    } elseif ($classification -eq 'protected') {
        $reason = Get-ProtectedReasonById $ProtectedCatalog ([string](Get-RooIndustriesPropertyValue $Process 'matchedProtectedItemId' ''))
        $blocked = $true
        $protected = $true
        $risk = 'protected'
        $confidence = 'high'
    } elseif ($classification -eq 'safeCandidate') {
        $safeRule = Get-ProfileSafeRuleById $Profile $ruleId
        $reason = [string](Get-RooIndustriesPropertyValue $safeRule 'reason' 'Manual-review candidate; no automatic priority change.')
        $risk = [string](Get-RooIndustriesPropertyValue $safeRule 'risk' 'low')
    }

    if ($actionSource) {
        $proposedAffinityMask = Get-RooIndustriesPropertyValue $actionSource 'affinityMask' (Get-RooIndustriesPropertyValue $actionSource 'processorAffinityMask' $null)
        $proposedIoPriority = Get-RooIndustriesPropertyValue $actionSource 'ioPriority' $null
        $proposedMemoryPriority = Get-RooIndustriesPropertyValue $actionSource 'memoryPriority' $proposedMemoryPriority
        $proposedGpuPriority = Get-RooIndustriesPropertyValue $actionSource 'gpuPriority' $null
    }

    $processId = [int](Get-RooIndustriesPropertyValue $Process 'pid' 0)
    $processName = [string](Get-RooIndustriesPropertyValue $Process 'name' '')
    $currentControls = Get-RooIndustriesProcessControlState $processId (Get-RooIndustriesPropertyValue $Process 'priorityClass' $null)
    $currentPriority = $currentControls.priorityClass
    $currentAffinityMask = $currentControls.affinityMask
    $currentIoPriority = $currentControls.ioPriority
    $currentMemoryPriority = $currentControls.memoryPriority
    $currentGpuPriority = $currentControls.gpuPriority
    $controlChanges = New-Object System.Collections.Generic.List[object]
    $canChange = [bool](Get-RooIndustriesPropertyValue $Process 'canChangePriority' $false)
    if ($Preset -eq 'placement' -and $actionSource) {
        if (-not (Test-RooIndustriesPriorityAllowed ([string]$currentPriority) -Restoring) -or
            -not (Test-RooIndustriesIoPriorityAllowed ([string]$currentIoPriority) -Restoring)) {
            $actionSource = $null
            $reason = 'The original priorities could not be read and restored, so this app is excluded.'
        }
        $processPlacement = if ($null -ne $currentControls.systemAffinityMask) {
            [pscustomobject]@{ mask = ([long]$Placement.mask -band [long]$currentControls.systemAffinityMask) }
        } else { $null }
        if ($actionSource -and ($null -eq $processPlacement -or $processPlacement.mask -eq 0)) {
            $actionSource = $null
            $reason = "The background CPUs are outside this app's system affinity mask."
        } elseif ($actionSource) {
            $proposedAffinityMask = $processPlacement.mask
            $canChange = $true
        }
    }

    if ($actionSource -and -not $protected -and -not $blocked -and $canChange) {
        if (-not [string]::IsNullOrWhiteSpace([string]$proposedPriority)) {
            if (-not (Test-RooIndustriesPriorityAllowed $proposedPriority)) {
                $reason = "Priority class '$proposedPriority' is outside the allow-list."
            } elseif ($null -eq $currentPriority -or [string]::IsNullOrWhiteSpace([string]$currentPriority)) {
                $reason = 'Current priority class could not be read, so no priority change is proposed.'
            } elseif ([string]$currentPriority -ne [string]$proposedPriority) {
                $controlChanges.Add((New-RooIndustriesControlChange 'priorityClass' $currentPriority $proposedPriority 'setPriority' $reason)) | Out-Null
            }
        }

        if ($null -ne $proposedAffinityMask) {
            if (-not (Test-RooIndustriesAffinityMaskAllowed $proposedAffinityMask)) {
                $reason = "Affinity mask '$proposedAffinityMask' is invalid."
            } elseif ($null -eq $currentAffinityMask) {
                $reason = 'Current CPU affinity could not be read, so no affinity change is proposed.'
            } elseif ([int64]$currentAffinityMask -ne [int64]$proposedAffinityMask) {
                $controlChanges.Add((New-RooIndustriesControlChange 'affinityMask' $currentAffinityMask ([int64]$proposedAffinityMask) 'setAffinity' 'Set process CPU affinity for the selected game profile.')) | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$proposedIoPriority)) {
            if (-not (Test-RooIndustriesIoPriorityAllowed $proposedIoPriority)) {
                $reason = "I/O priority '$proposedIoPriority' is outside the allow-list."
            } elseif ([string]::IsNullOrWhiteSpace([string]$currentIoPriority)) {
                $reason = 'Current I/O priority could not be read, so no I/O priority change is proposed.'
            } elseif ([string]$currentIoPriority -ne [string]$proposedIoPriority) {
                $controlChanges.Add((New-RooIndustriesControlChange 'ioPriority' $currentIoPriority $proposedIoPriority 'setIoPriority' 'Set process I/O priority for the selected game profile.')) | Out-Null
            }
        }

        if ($null -ne $proposedMemoryPriority) {
            $memoryChange = New-RooIndustriesControlChange 'memoryPriority' $currentMemoryPriority $proposedMemoryPriority 'setMemoryPriority' 'Set process memory priority for the selected profile.'
            $memoryReason = Get-RooIndustriesControlChangeValidationReason $memoryChange $currentControls
            if ($null -ne $currentControls.process -and (Test-RooIndustriesGovernorOwnsControl $currentControls.process 'memoryPriority')) {
                $memoryReason = $script:RooIndustriesGovernorManaged
            }
            if ($memoryReason) {
                $memoryChange.blocked = $true
                $memoryChange.blockedReason = $memoryReason
                $controlChanges.Add($memoryChange) | Out-Null
            } elseif (-not (Test-RooIndustriesControlValueEqual 'memoryPriority' $currentMemoryPriority $proposedMemoryPriority)) {
                $controlChanges.Add($memoryChange) | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$proposedGpuPriority)) {
            if (-not (Test-RooIndustriesGpuPriorityAllowed $proposedGpuPriority)) {
                $reason = "GPU priority '$proposedGpuPriority' is outside the allow-list."
                $blocked = $true
                $rollbackSupported = $false
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $proposedGpuPriority 'setGpuPriority' 'Requested GPU scheduling priority is outside the allow-list.' $true $reason)) | Out-Null
            } elseif (-not [bool](Get-RooIndustriesPropertyValue $currentControls 'gpuPriorityAvailable' $false)) {
                $reason = 'GPU scheduling priority is unavailable for this process.'
                $blocked = $true
                $rollbackSupported = $false
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $proposedGpuPriority 'setGpuPriority' 'Native GPU scheduling priority is unavailable for this process.' $true $reason)) | Out-Null
            } elseif ([string]$currentGpuPriority -ne [string]$proposedGpuPriority) {
                $controlChanges.Add((New-RooIndustriesControlChange 'gpuPriority' $currentGpuPriority $proposedGpuPriority 'setGpuPriority' 'Set process GPU scheduling priority for the selected game profile.')) | Out-Null
            }
        }
    } elseif ($actionSource -and -not $canChange) {
        $blocked = $true
        $rollbackSupported = $false
        $reason = 'Process is not safe to change from this profile pass.'
    }

    if ($blocked) {
        $proposedAction = 'noChange'
        $rollbackSupported = $false
    } elseif ($controlChanges.Count -gt 0) {
        $proposedAction = if ($controlChanges.Count -eq 1 -and [string](Get-RooIndustriesPropertyValue $controlChanges[0] 'action' '') -eq 'setPriority') { 'setPriority' } else { 'setProcessControls' }
        $rollbackSupported = $true
        foreach ($change in @($controlChanges.ToArray())) {
            switch ([string](Get-RooIndustriesPropertyValue $change 'control' '')) {
                'priorityClass' { $proposedPriority = Get-RooIndustriesPropertyValue $change 'proposedValue' $proposedPriority }
                'affinityMask' { $proposedAffinityMask = Get-RooIndustriesPropertyValue $change 'proposedValue' $proposedAffinityMask }
                'ioPriority' { $proposedIoPriority = Get-RooIndustriesPropertyValue $change 'proposedValue' $proposedIoPriority }
                'memoryPriority' { $proposedMemoryPriority = Get-RooIndustriesPropertyValue $change 'proposedValue' $proposedMemoryPriority }
                'gpuPriority' { $proposedGpuPriority = Get-RooIndustriesPropertyValue $change 'proposedValue' $proposedGpuPriority }
            }
        }
    } else {
        $proposedPriority = $currentPriority
        $proposedAffinityMask = $currentAffinityMask
        $proposedIoPriority = $currentIoPriority
        $proposedMemoryPriority = $currentMemoryPriority
        $proposedGpuPriority = $currentGpuPriority
        $rollbackSupported = $false
    }

    $previewId = (($ruleId, $classification, $processName, $processId) -join '-').ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
    if ([string]::IsNullOrWhiteSpace($ruleId)) { $ruleId = $classification }

    return [pscustomobject]@{
        previewId = $previewId
        type = if ($controlChanges.Count -gt 1) { 'processControls' } else { 'processPriority' }
        target = "$processName`:$processId"
        displayName = Get-RooIndustriesPropertyValue $Process 'displayName' $processName
        processId = $processId
        processName = $processName
        executablePath = Get-RooIndustriesPropertyValue $Process 'executablePath' $null
        processStartTimeUtc = $currentControls.startTimeUtc
        currentPriorityClass = $currentPriority
        proposedPriorityClass = $proposedPriority
        currentAffinityMask = $currentAffinityMask
        proposedAffinityMask = $proposedAffinityMask
        currentIoPriority = $currentIoPriority
        currentMemoryPriority = $currentMemoryPriority
        proposedIoPriority = $proposedIoPriority
        proposedMemoryPriority = $proposedMemoryPriority
        memoryPriorityAvailable = Get-RooIndustriesPropertyValue $currentControls 'memoryPriorityAvailable' $false
        memoryPriorityStatus = Get-RooIndustriesPropertyValue $currentControls 'memoryPriorityStatus' $null
        currentGpuPriority = $currentGpuPriority
        proposedGpuPriority = $proposedGpuPriority
        gpuPriorityAvailable = Get-RooIndustriesPropertyValue $currentControls 'gpuPriorityAvailable' $false
        gpuPriorityStatus = Get-RooIndustriesPropertyValue $currentControls 'gpuPriorityStatus' $null
        proposedAction = $proposedAction
        controlChanges = @($controlChanges.ToArray())
        ruleId = $ruleId
        reason = $reason
        reasonCodes = @(Get-RooIndustriesPropertyArray $Process 'reasonCodes')
        classification = $classification
        blocked = $blocked
        blockedReason = if ($blocked) { $reason } else { $null }
        risk = $risk
        confidence = $confidence
        protected = $protected
        requiresConfirmation = ($controlChanges.Count -gt 0 -and -not $blocked)
        rollbackSupported = $rollbackSupported
        currentState = [pscustomobject]@{
            priorityClass = $currentPriority
            affinityMask = $currentAffinityMask
            ioPriority = $currentIoPriority
            memoryPriority = $currentMemoryPriority
            gpuPriority = $currentGpuPriority
            workingSetBytes = Get-RooIndustriesPropertyValue $Process 'workingSetBytes' 0
            privateBytes = Get-RooIndustriesPropertyValue $Process 'privateBytes' $null
            cpuPercent = Get-RooIndustriesPropertyValue $Process 'cpuPercent' $null
            classification = $classification
        }
        proposedState = [pscustomobject]@{
            action = $proposedAction
            priorityClass = $proposedPriority
            affinityMask = $proposedAffinityMask
            ioPriority = $proposedIoPriority
            memoryPriority = $proposedMemoryPriority
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
                restoreMemoryPriority = $currentMemoryPriority
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
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $catalogPathValue = [string](Get-RooIndustriesPropertyValue $profile 'protectedCatalogPath' 'protected-processes.json')
    $protectedCatalogPath = if ([System.IO.Path]::IsPathRooted($catalogPathValue)) {
        $catalogPathValue
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Split-Path $resolvedProfilePath -Parent) $catalogPathValue))
    }
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath

    $classificationArgs = @{ ProfilePath = $resolvedProfilePath }
    if (-not [string]::IsNullOrWhiteSpace($TargetGameProcessName)) {
        $classificationArgs['TargetGameProcessName'] = $TargetGameProcessName
    }
    $classification = & (Join-Path $PSScriptRoot 'Get-ProcessClassification.ps1') @classificationArgs | ConvertFrom-Json
    $placement = if ($Preset -eq 'placement') { Read-RooIndustriesBackgroundPlacement } else { $null }

    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-RooIndustriesPropertyArray $classification 'processes')) {
        $className = [string](Get-RooIndustriesPropertyValue $proc 'classification' 'unknown')
        $include = ([bool](Get-RooIndustriesPropertyValue $proc 'sessionProfileMatched' $false)) -or ($className -in @('gameTarget', 'demotionCandidate', 'protectedCompanion'))
        if (-not $include) { continue }
        $preview.Add((New-ProcessPreviewEntry $proc $profile $protectedCatalog $placement)) | Out-Null
    }

    $warnings = New-Object System.Collections.Generic.List[object]
    $warnings.Add((New-RooIndustriesIssue 'PROCESS_PROFILE_PREVIEW_ONLY' 'Preview built without applying process priority changes.' 'info' 'performance.profile' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Run Apply-ProcessProfile.ps1 with -ConfirmApply only after reviewing the preview.' $null)) | Out-Null
    if ($preview.Count -eq 0) {
        $warnings.Add((New-RooIndustriesIssue 'NO_MATCHING_PROCESSES' 'No running processes matched this profile.' 'warning' 'performance.profile' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Launch the target game or companion apps, then preview again.' $null)) | Out-Null
    }

    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.previewProfile' `
        -DryRun $true `
        -Risk ([string](Get-RooIndustriesPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status 'preview' `
        -Preview @($preview.ToArray()) `
        -Backup $null `
        -Result $null `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooIndustriesLog "Preview generated for profile $([string](Get-RooIndustriesPropertyValue $profile 'profileId' ''))."))

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.previewProfile' `
        -DryRun $true `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIndustriesIssue 'PROCESS_PROFILE_PREVIEW_FAILED' $_.Exception.Message 'error' 'performance.profile' $ProfilePath $true 'Check the profile path and process inventory script.' $null)) `
        -Logs @((New-RooIndustriesLog 'Preview failed.' 'error'))
    Write-RooIndustriesJsonOutput $envelope $OutputPath
    exit 1
}
