param(
    [string]$ProfilePath = '',
    [string]$TargetGameProcessName = '',
    [switch]$IncludeCommandLine,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
. (Join-Path $PSScriptRoot 'BackgroundPlacement.Common.ps1')

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\game-session.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath

    $catalogPathValue = [string](Get-RooIndustriesPropertyValue $profile 'protectedCatalogPath' 'protected-processes.json')
    if ([System.IO.Path]::IsPathRooted($catalogPathValue)) {
        $protectedCatalogPath = $catalogPathValue
    } else {
        $protectedCatalogPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $resolvedProfilePath -Parent) $catalogPathValue))
    }
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath

    $inventoryScript = Join-Path $PSScriptRoot 'Get-ProcessInventory.ps1'
    if ($IncludeCommandLine) {
        $inventory = & $inventoryScript -IncludeCommandLine | ConvertFrom-Json
    } else {
        $inventory = & $inventoryScript | ConvertFrom-Json
    }

    $classified = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-RooIndustriesPropertyArray $inventory 'processes')) {
        $info = Get-RooIndustriesProcessClassificationInfo $proc $profile $protectedCatalog $TargetGameProcessName
        $memoryState = $null
        try {
            $memoryProcess = Get-Process -Id ([int]$proc.pid) -ErrorAction Stop
            $memoryState = Get-RooIndustriesProcessMemoryPriority $memoryProcess
        } catch { $memoryState = [pscustomobject]@{ available = $false; value = $null; name = $null; status = $_.Exception.Message } }
        $classifiedProcess = [pscustomobject]@{
            pid = [int](Get-RooIndustriesPropertyValue $proc 'pid' 0)
            name = [string](Get-RooIndustriesPropertyValue $proc 'name' '')
            displayName = Get-RooIndustriesPropertyValue $proc 'displayName' $null
            executablePath = Get-RooIndustriesPropertyValue $proc 'executablePath' $null
            publisher = Get-RooIndustriesPropertyValue $proc 'publisher' $null
            commandLine = if ($IncludeCommandLine) { Get-RooIndustriesPropertyValue $proc 'commandLine' $null } else { $null }
            category = [string](Get-RooIndustriesPropertyValue $proc 'category' 'unknown')
            protection = [string](Get-RooIndustriesPropertyValue $proc 'protection' 'unknown')
            classification = $info.classification
            reasonCodes = @($info.reasonCodes)
            matchedRuleId = $info.matchedRuleId
            matchedProtectedItemId = $info.matchedProtectedItemId
            matchedProfileItemId = $info.matchedProfileItemId
            sessionProfileMatched = [bool]$info.sessionProfileMatched
            profileMatched = [bool]$info.profileMatched
            blocked = [bool]$info.blocked
            protected = [bool]$info.protected
            sessionId = Get-RooIndustriesPropertyValue $proc 'sessionId' $null
            priorityClass = Get-RooIndustriesPropertyValue $proc 'priorityClass' $null
            memoryPriority = $memoryState.value
            memoryPriorityName = $memoryState.name
            memoryPriorityAvailable = $memoryState.available
            memoryPriorityStatus = [string]$memoryState.status
            cpuPercent = Get-RooIndustriesPropertyValue $proc 'cpuPercent' $null
            workingSetBytes = [uint64](Get-RooIndustriesPropertyValue $proc 'workingSetBytes' 0)
            privateBytes = Get-RooIndustriesPropertyValue $proc 'privateBytes' $null
            gpuDedicatedBytes = Get-RooIndustriesPropertyValue $proc 'gpuDedicatedBytes' $null
            gpuSharedBytes = Get-RooIndustriesPropertyValue $proc 'gpuSharedBytes' $null
            isForegroundCandidate = [bool](Get-RooIndustriesPropertyValue $proc 'isForegroundCandidate' $false)
            canChangePriority = [bool]$info.canChangePriority
            risk = $info.risk
        }
        $classifiedProcess | Add-Member -NotePropertyName backgroundPlacementEligible -NotePropertyValue (Test-RooIndustriesBackgroundPlacementCandidate $classifiedProcess $profile $protectedCatalog $TargetGameProcessName)
        $classified.Add($classifiedProcess) | Out-Null
    }

    $processArray = @($classified.ToArray())
    $classCounts = @{}
    foreach ($className in @('gameTarget', 'protected', 'protectedCompanion', 'safeCandidate', 'demotionCandidate', 'unknown')) {
        $classCounts[$className] = @($processArray | Where-Object { $_.classification -eq $className }).Count
    }

    $result = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        source = 'local-process-inventory'
        profileId = [string](Get-RooIndustriesPropertyValue $profile 'profileId' '')
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
            sourceInventorySummary = Get-RooIndustriesPropertyValue $inventory 'summary' $null
        }
        processes = $processArray
    }

    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
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
            (New-RooIndustriesIssue 'PROCESS_CLASSIFICATION_FAILED' $_.Exception.Message 'error' 'performance.classification' $ProfilePath $true 'Check the profile and protected process catalog paths.' $null)
        )
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
