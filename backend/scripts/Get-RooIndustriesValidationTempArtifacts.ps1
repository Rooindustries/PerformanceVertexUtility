param(
    [string]$ArtifactRoot = '',
    [int]$MinimumAgeMinutes = 60,
    [string[]]$ProtectPath = @(),
    [string]$OutputPath = '',
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Test-PathInsideRoot {
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

function Get-ArtifactKind {
    param([string]$Name)
    if ($Name -like 'roo-industries-uninstall*') { return 'uninstall-cleanup-validation' }
    if ($Name -like 'roo-industries-stutter*') { return 'stutter-validation' }
    if ($Name -like 'roo-industries-nvidia*' -or $Name -like 'roo-industries-nip*' -or $Name -like 'RooIndustriesNvidia*') { return 'nvidia-nip-validation' }
    if ($Name -like 'roo-industries-process*' -or $Name -like 'roo-industries-policy*' -or $Name -like 'roo-industries-resident*') { return 'process-runtime-validation' }
    if ($Name -like 'roo-industries-power-plan-import*') { return 'power-plan-validation' }
    if ($Name -like 'RooIndustriesBackend*' -or $Name -like 'RooIndustriesStutter*') { return 'backend-validation' }
    return 'roo-industries-validation'
}

try {
    if ($MinimumAgeMinutes -lt 0) { $MinimumAgeMinutes = 0 }
    $root = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { [System.IO.Path]::GetTempPath() } else { Resolve-RooIndustriesPath $ArtifactRoot $ArtifactRoot }
    $root = [System.IO.Path]::GetFullPath($root)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Artifact root does not exist: $root"
    }
    $protectedPaths = @($ProtectPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.IO.Path]::GetFullPath((Resolve-RooIndustriesPath $_ $_)) })
    $patterns = @('roo-industries-*','RooIndustriesBackend*','RooIndustriesNvidia*','RooIndustriesStutter*')
    $seen = @{}
    $now = Get-Date
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $patterns) {
        foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue -Filter $pattern)) {
            $fullPath = [System.IO.Path]::GetFullPath($item.FullName)
            $key = $fullPath.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $ageMinutes = [int][math]::Floor(($now - $item.LastWriteTime).TotalMinutes)
            $explicitlyProtected = (@($protectedPaths | Where-Object { Test-PathInsideRoot $fullPath $_ }).Count -gt 0)
            $recentProtected = ($ageMinutes -lt $MinimumAgeMinutes)
            $protected = ($explicitlyProtected -or $recentProtected)
            $wouldDelete = ([bool]$Cleanup -and -not $protected)
            $deleted = $false
            $deleteError = $null
            if ($wouldDelete) {
                try {
                    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
                    $deleted = -not (Test-Path -LiteralPath $fullPath)
                } catch {
                    $deleteError = $_.Exception.Message
                }
            }
            $items.Add([pscustomobject]@{
                path = $fullPath
                name = $item.Name
                kind = Get-ArtifactKind $item.Name
                itemType = if ($item.PSIsContainer) { 'directory' } else { 'file' }
                lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
                ageMinutes = $ageMinutes
                protected = $protected
                protectionReasons = @(
                    if ($explicitlyProtected) { 'explicit-protect-path' }
                    if ($recentProtected) { 'younger-than-minimum-age' }
                )
                wouldDelete = $wouldDelete
                deleted = $deleted
                deleteError = $deleteError
            }) | Out-Null
        }
    }
    $artifactArray = @($items.ToArray() | Sort-Object path)
    $result = [pscustomobject]@{
        actionId = 'backend.validationTempArtifacts.audit'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        artifactRoot = $root
        dryRun = (-not [bool]$Cleanup)
        cleanupRequested = [bool]$Cleanup
        minimumAgeMinutes = $MinimumAgeMinutes
        protectedPaths = @($protectedPaths)
        artifacts = $artifactArray
        summary = [pscustomobject]@{
            artifactCount = $artifactArray.Count
            protectedCount = @($artifactArray | Where-Object { $_.protected }).Count
            oldUnprotectedCount = @($artifactArray | Where-Object { -not $_.protected }).Count
            wouldDeleteCount = @($artifactArray | Where-Object { $_.wouldDelete }).Count
            deletedCount = @($artifactArray | Where-Object { $_.deleted }).Count
            deleteErrorCount = @($artifactArray | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.deleteError) }).Count
        }
        warnings = @()
        errors = @()
        logs = @((New-RooIndustriesLog 'Validation temp artifact audit completed.'))
    }
    Write-RooIndustriesJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'backend.validationTempArtifacts.audit'
        schemaVersion = 1
        productName = $script:RooIndustriesProcessProductName
        capturedAtUtc = Get-RooIndustriesUtcStamp
        dryRun = $true
        cleanupRequested = [bool]$Cleanup
        artifacts = @()
        summary = [pscustomobject]@{ artifactCount = 0; deletedCount = 0 }
        errors = @((New-RooIndustriesIssue 'VALIDATION_TEMP_AUDIT_FAILED' $_.Exception.Message 'error' 'backend.validationTempArtifacts' $ArtifactRoot $true 'Check artifact root and retry.' $null))
        logs = @((New-RooIndustriesLog 'Validation temp artifact audit failed.' 'error'))
    }
    Write-RooIndustriesJsonOutput $errorResult $OutputPath
    exit 1
}
