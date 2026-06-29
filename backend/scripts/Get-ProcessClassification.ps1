param(
    [string]$ProfilePath = '',
    [string]$TargetGameProcessName = '',
    [switch]$IncludeCommandLine,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\game-session.profile.json'
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath

    $catalogPathValue = [string](Get-RooPropertyValue $profile 'protectedCatalogPath' 'protected-processes.json')
    if ([System.IO.Path]::IsPathRooted($catalogPathValue)) {
        $protectedCatalogPath = $catalogPathValue
    } else {
        $protectedCatalogPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $resolvedProfilePath -Parent) $catalogPathValue))
    }
    $protectedCatalog = Read-RooJsonFile $protectedCatalogPath

    $inventoryScript = Join-Path $PSScriptRoot 'Get-ProcessInventory.ps1'
    if ($IncludeCommandLine) {
        $inventory = & $inventoryScript -IncludeCommandLine | ConvertFrom-Json
    } else {
        $inventory = & $inventoryScript | ConvertFrom-Json
    }

    $classified = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-RooPropertyArray $inventory 'processes')) {
        $info = Get-RooProcessClassificationInfo $proc $profile $protectedCatalog $TargetGameProcessName
        $classified.Add([pscustomobject]@{
            pid = [int](Get-RooPropertyValue $proc 'pid' 0)
            name = [string](Get-RooPropertyValue $proc 'name' '')
            displayName = Get-RooPropertyValue $proc 'displayName' $null
            executablePath = Get-RooPropertyValue $proc 'executablePath' $null
            publisher = Get-RooPropertyValue $proc 'publisher' $null
            commandLine = if ($IncludeCommandLine) { Get-RooPropertyValue $proc 'commandLine' $null } else { $null }
            category = [string](Get-RooPropertyValue $proc 'category' 'unknown')
            protection = [string](Get-RooPropertyValue $proc 'protection' 'unknown')
            classification = $info.classification
            reasonCodes = @($info.reasonCodes)
            matchedRuleId = $info.matchedRuleId
            matchedProtectedItemId = $info.matchedProtectedItemId
            matchedProfileItemId = $info.matchedProfileItemId
            sessionProfileMatched = [bool]$info.sessionProfileMatched
            profileMatched = [bool]$info.profileMatched
            blocked = [bool]$info.blocked
            protected = [bool]$info.protected
            sessionId = Get-RooPropertyValue $proc 'sessionId' $null
            priorityClass = Get-RooPropertyValue $proc 'priorityClass' $null
            cpuPercent = Get-RooPropertyValue $proc 'cpuPercent' $null
            workingSetBytes = [uint64](Get-RooPropertyValue $proc 'workingSetBytes' 0)
            privateBytes = Get-RooPropertyValue $proc 'privateBytes' $null
            gpuDedicatedBytes = Get-RooPropertyValue $proc 'gpuDedicatedBytes' $null
            gpuSharedBytes = Get-RooPropertyValue $proc 'gpuSharedBytes' $null
            isForegroundCandidate = [bool](Get-RooPropertyValue $proc 'isForegroundCandidate' $false)
            canChangePriority = [bool]$info.canChangePriority
            risk = $info.risk
        }) | Out-Null
    }

    $processArray = @($classified.ToArray())
    $classCounts = @{}
    foreach ($className in @('gameTarget', 'protected', 'protectedCompanion', 'safeCandidate', 'demotionCandidate', 'unknown')) {
        $classCounts[$className] = @($processArray | Where-Object { $_.classification -eq $className }).Count
    }

    $result = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        source = 'local-process-inventory'
        profileId = [string](Get-RooPropertyValue $profile 'profileId' '')
        profilePath = $resolvedProfilePath
        protectedCatalogPath = $protectedCatalogPath
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        summary = [pscustomobject]@{
            processCount = $processArray.Count
            classCounts = $classCounts
            sessionProfileMatchedCount = @($processArray | Where-Object { $_.sessionProfileMatched }).Count
            protectedCount = @($processArray | Where-Object { $_.classification -in @('protected', 'protectedCompanion') }).Count
            demotionCandidateCount = @($processArray | Where-Object { $_.classification -eq 'demotionCandidate' }).Count
            gameTargetCount = @($processArray | Where-Object { $_.classification -eq 'gameTarget' }).Count
            workingSetBytes = [uint64](($processArray | Measure-Object workingSetBytes -Sum).Sum)
            privateBytes = [uint64](($processArray | Measure-Object privateBytes -Sum).Sum)
            sourceInventorySummary = Get-RooPropertyValue $inventory 'summary' $null
        }
        processes = $processArray
    }

    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        source = 'local-process-inventory'
        profileId = $null
        profilePath = $ProfilePath
        protectedCatalogPath = $null
        targetGameProcessName = if ([string]::IsNullOrWhiteSpace($TargetGameProcessName)) { $null } else { $TargetGameProcessName }
        summary = [pscustomobject]@{
            processCount = 0
            classCounts = @{}
            sessionProfileMatchedCount = 0
            protectedCount = 0
            demotionCandidateCount = 0
            gameTargetCount = 0
            workingSetBytes = 0
            privateBytes = 0
            sourceInventorySummary = $null
        }
        processes = @()
        errors = @(
            (New-RooIssue 'PROCESS_CLASSIFICATION_FAILED' $_.Exception.Message 'error' 'performance.classification' $ProfilePath $true 'Check the profile and protected process catalog paths.' $null)
        )
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
