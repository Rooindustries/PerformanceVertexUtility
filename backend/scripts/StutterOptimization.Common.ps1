. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooIndustriesStutterProductName = 'Roo Industries Optimization Suite'
$script:RooIndustriesStutterOptimizationIds = @(
    'standby-memory',
    'timer-resolution',
    'power-plan',
    'shader-cache-cleanup',
    'service-pause-preview'
)

function New-RooIndustriesStutterIssue {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Severity = 'warning',
        [string]$Target = $null,
        [bool]$Blocking = $false,
        [string]$RecommendedAction = $null,
        [object]$Details = $null
    )
    return [pscustomobject]@{
        code = $Code
        message = $Message
        severity = $Severity
        source = 'performance.stutterOptimization'
        target = $Target
        blocking = $Blocking
        recommendedAction = $RecommendedAction
        details = $Details
    }
}

function New-RooIndustriesStutterGate {
    param(
        [string]$GateId,
        [string]$Name,
        [bool]$Required,
        [bool]$Satisfied,
        [string]$Reason,
        [object]$Evidence = $null
    )
    return [pscustomobject]@{
        gateId = $GateId
        name = $Name
        required = $Required
        satisfied = $Satisfied
        blocking = ($Required -and -not $Satisfied)
        reason = $Reason
        evidence = $Evidence
    }
}

function Test-RooIndustriesStutterPathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootWithSlash = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-RooIndustriesStutterPathInsideTemp {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RooIndustriesStutterJsonInput {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return Read-RooIndustriesJsonFile (Resolve-RooIndustriesPath $Path $Path)
}

function Get-RooIndustriesStutterMemorySnapshot {
    param([string]$MemorySnapshotPath)
    $provided = Get-RooIndustriesStutterJsonInput $MemorySnapshotPath
    if ($provided) { return $provided }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($null -eq $os) {
        return [pscustomobject]@{
            source = 'unavailable'
            totalPhysicalBytes = $null
            availableBytes = $null
            standbyBytes = $null
            commitUsedBytes = $null
            commitLimitBytes = $null
        }
    }
    return [pscustomobject]@{
        source = 'live-readonly-os-memory'
        totalPhysicalBytes = [uint64]$os.TotalVisibleMemorySize * 1024
        availableBytes = [uint64]$os.FreePhysicalMemory * 1024
        standbyBytes = $null
        commitUsedBytes = $null
        commitLimitBytes = $null
    }
}

function Get-RooIndustriesStutterShaderCacheItems {
    param([string]$ShaderCacheRoot)
    $items = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot) -or -not (Test-Path -LiteralPath $ShaderCacheRoot)) {
        return @($items.ToArray())
    }
    $root = [System.IO.Path]::GetFullPath($ShaderCacheRoot)
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\','/')
        $family = if ($relative -match 'nvidia') { 'nvidia' } elseif ($relative -match 'directx|dxcache|d3d') { 'directx' } elseif ($relative -match 'amd') { 'amd' } elseif ($relative -match 'intel') { 'intel' } elseif ($relative -match 'steam') { 'steam' } else { 'unknown' }
        $items.Add([pscustomobject]@{
            itemId = 'shader-cache:' + ((($relative.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')))
            type = 'file'
            cacheFamily = $family
            path = $file.FullName
            relativePath = $relative
            bytes = [uint64]$file.Length
            protected = $false
            defaultSelected = $true
            reason = 'Disposable shader-cache fixture item.'
        }) | Out-Null
    }
    return @($items.ToArray())
}

function New-RooIndustriesStutterRollbackManifestId {
    param([string]$OptimizationId)
    return 'stutter-' + (($OptimizationId.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')) + '-rollback-' + (Get-RooIndustriesFileStamp)
}

