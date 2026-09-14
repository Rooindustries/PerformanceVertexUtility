param(
    [string]$UtilitiesRoot = '',
    [string]$CorrelationId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Resolve-UtilitiesRoot {
    param([string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ROO_UTILITIES_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:ROO_UTILITIES_ROOT)
    }
    return [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities'))
}

function New-FileFact {
    param(
        [string]$Name,
        [string]$Path
    )

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $version = $null
    $length = $null
    $lastWriteTimeUtc = $null
    if ($exists) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $versionInfo = $item.VersionInfo
        $version = if (-not [string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) { $versionInfo.FileVersion } else { $null }
        $length = [int64]$item.Length
        $lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    }

    return [pscustomobject]@{
        name = $Name
        path = $Path
        exists = [bool]$exists
        version = $version
        length = $length
        lastWriteTimeUtc = $lastWriteTimeUtc
        launched = $false
    }
}

$startedAtUtc = Get-UtcStamp
if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
    $CorrelationId = "process-control-facts-$([guid]::NewGuid().ToString('N'))"
}

try {
    $resolvedUtilitiesRoot = Resolve-UtilitiesRoot $UtilitiesRoot
    $affToolRoot = Join-Path $resolvedUtilitiesRoot 'AffTool'
    $affToolX64 = Join-Path $affToolRoot 'intPolicy_x64.exe'
    $affToolX86 = Join-Path $affToolRoot 'intPolicy_x86.exe'
    $affToolIa64 = Join-Path $affToolRoot 'intPolicy_ia64.exe'

    [pscustomobject]@{
        actionId = 'performance.processControls.facts'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        correlationId = $CorrelationId
        dryRun = $true
        status = 'completed'
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-UtcStamp
        facts = [pscustomobject]@{
            builtinMechanisms = @(
                [pscustomobject]@{ name = 'CPU Priority'; target = 'kernel32!SetPriorityClass'; detectable = $true },
                [pscustomobject]@{ name = 'CPU Affinity'; target = 'kernel32!SetProcessAffinityMask'; detectable = $true },
                [pscustomobject]@{ name = 'I/O Priority'; target = 'ntdll!NtSetInformationProcess(ProcessIoPriorityInformationClass=33)'; detectable = $true },
                [pscustomobject]@{ name = 'GPU Priority'; target = 'gdi32!D3DKMTSetProcessSchedulingPriorityClass'; detectable = $true }
            )
            utilitiesRoot = $resolvedUtilitiesRoot
            externalTools = @(
                New-FileFact 'AffTool x64 affinity policy tool' $affToolX64
                New-FileFact 'AffTool x86 affinity policy tool' $affToolX86
                New-FileFact 'AffTool ia64 affinity policy tool' $affToolIa64
            )
        }
        warnings = @()
        errors = @()
        logs = @(
            [pscustomobject]@{
                timestampUtc = Get-UtcStamp
                level = 'info'
                message = 'Process control capability facts collected without launching external tools.'
            }
        )
    } | ConvertTo-Json -Depth 8
} catch {
    [pscustomobject]@{
        actionId = 'performance.processControls.facts'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        correlationId = $CorrelationId
        dryRun = $true
        status = 'failed'
        startedAtUtc = $startedAtUtc
        completedAtUtc = Get-UtcStamp
        facts = $null
        warnings = @()
        errors = @(
            [pscustomobject]@{
                code = 'PROCESS_CONTROL_FACTS_FAILED'
                message = $_.Exception.Message
                severity = 'error'
                source = 'performance.processControls'
                target = $UtilitiesRoot
                blocking = $true
                recommendedAction = 'Check utilities-root access and retry.'
                details = $null
            }
        )
        logs = @()
    } | ConvertTo-Json -Depth 8
    exit 1
}
