param(
    [string]$UtilitiesRoot = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CleanupToolUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Resolve-CleanupToolUtilitiesRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        return [System.IO.Path]::GetFullPath($Root)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_UTILITIES_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:ROO_INDUSTRIES_UTILITIES_ROOT)
    }
    return [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities'))
}

function Resolve-CleanupToolOutputPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Write-CleanupToolJsonOutput {
    param(
        [object]$Value,
        [string]$Path
    )
    $json = $Value | ConvertTo-Json -Depth 16
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = Resolve-CleanupToolOutputPath $Path
        $parent = Split-Path $resolved -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-CleanupToolFileFact {
    param(
        [string]$ToolId,
        [string]$DisplayName,
        [string]$ExpectedPath,
        [string]$FutureRunner
    )
    $exists = Test-Path -LiteralPath $ExpectedPath -PathType Leaf
    $item = if ($exists) { Get-Item -LiteralPath $ExpectedPath } else { $null }
    return [pscustomobject]@{
        toolId = $ToolId
        displayName = $DisplayName
        expectedPath = $ExpectedPath
        exists = $exists
        lengthBytes = if ($item) { [int64]$item.Length } else { $null }
        productVersion = if ($item) { [string]$item.VersionInfo.ProductVersion } else { $null }
        fileVersion = if ($item) { [string]$item.VersionInfo.FileVersion } else { $null }
        companyName = if ($item) { [string]$item.VersionInfo.CompanyName } else { $null }
        lastWriteTimeUtc = if ($item) { $item.LastWriteTimeUtc.ToString('o') } else { $null }
        detectionMode = 'file-version-only'
        launchAttempted = $false
        futureRunner = $FutureRunner
    }
}

$startedAtUtc = Get-CleanupToolUtcStamp
$correlationId = [guid]::NewGuid().ToString('N')

try {
    $root = Resolve-CleanupToolUtilitiesRoot $UtilitiesRoot
    $tools = @(
        (Get-CleanupToolFileFact `
            -ToolId 'sysinternals-autoruns' `
            -DisplayName 'Sysinternals Autoruns' `
            -ExpectedPath (Join-Path $root 'autoruns.exe') `
            -FutureRunner 'Future hidden autoruns.exe autorunsc-style CSV export allowlist runner; read-only export before any startup mutation.'),
        (Get-CleanupToolFileFact `
            -ToolId 'devicecleanup' `
            -DisplayName 'DeviceCleanup' `
            -ExpectedPath (Join-Path $root 'Other\DeviceCleanup.exe') `
            -FutureRunner 'Future read-only device enumeration/export helper before any exact device-instance allowlist cleanup runner.')
    )
    $present = @($tools | Where-Object { $_.exists })
    $result = [pscustomobject]@{
        actionId = 'apps.cleanupToolFacts'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        correlationId = $correlationId
        capturedAtUtc = Get-CleanupToolUtcStamp
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-CleanupToolUtcStamp
        dryRun = $true
        status = 'completed'
        utilitiesRoot = $root
        tools = @($tools)
        summary = [pscustomobject]@{
            toolCount = @($tools).Count
            presentCount = $present.Count
            missingCount = (@($tools).Count - $present.Count)
            willLaunchTools = $false
            willChangeSystem = $false
        }
        warnings = @()
        errors = @()
        logs = @(
            [pscustomobject]@{
                timestampUtc = Get-CleanupToolUtcStamp
                level = 'info'
                message = 'Cleanup utility facts collected without launching tools.'
            }
        )
    }
    Write-CleanupToolJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'apps.cleanupToolFacts'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        correlationId = $correlationId
        capturedAtUtc = Get-CleanupToolUtcStamp
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-CleanupToolUtcStamp
        dryRun = $true
        status = 'failed'
        utilitiesRoot = $UtilitiesRoot
        tools = @()
        summary = [pscustomobject]@{
            toolCount = 0
            presentCount = 0
            missingCount = 0
            willLaunchTools = $false
            willChangeSystem = $false
        }
        warnings = @()
        errors = @(
            [pscustomobject]@{
                code = 'CLEANUP_TOOL_FACTS_FAILED'
                message = $_.Exception.Message
                severity = 'error'
                source = 'apps.cleanupToolFacts'
                target = $UtilitiesRoot
                blocking = $true
                recommendedAction = 'Check the Utilities root path and retry detection.'
            }
        )
        logs = @(
            [pscustomobject]@{
                timestampUtc = Get-CleanupToolUtcStamp
                level = 'error'
                message = 'Cleanup utility fact collection failed.'
            }
        )
    }
    Write-CleanupToolJsonOutput $errorResult $OutputPath
    exit 1
}
