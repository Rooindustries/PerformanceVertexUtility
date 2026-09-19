param(
    [string]$UtilitiesRoot = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CapabilityRouter.Common.ps1')

function New-RooIndustriesCapabilityEntry {
    param(
        [object]$Capability,
        [object]$ResolvedAvailability
    )

    $entry = [ordered]@{}
    foreach ($property in $Capability.PSObject.Properties) {
        $entry[$property.Name] = $property.Value
    }
    $entry['resolvedAvailability'] = $ResolvedAvailability
    return [pscustomobject]$entry
}

function Convert-GroupsToCountObject {
    param([object[]]$Groups)

    $map = [ordered]@{}
    foreach ($group in $Groups) {
        $map[[string]$group.Name] = [int]$group.Count
    }
    return [pscustomobject]$map
}

$startedAtUtc = Get-RooIndustriesUtcStamp
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$capabilityRoot = Join-Path $repoRoot 'backend\capabilities'
$resolvedUtilitiesRoot = Resolve-RooIndustriesUtilitiesRoot $UtilitiesRoot
$gpuInventory = Get-RooIndustriesGpuInventory

$fragments = @(Get-ChildItem -LiteralPath $capabilityRoot -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
})

$capabilities = New-Object System.Collections.Generic.List[object]
foreach ($fragment in $fragments) {
    foreach ($capability in @($fragment.capabilities)) {
        $resolvedAvailability = Resolve-RooIndustriesCapabilityAvailability $capability $repoRoot $resolvedUtilitiesRoot $gpuInventory
        $capabilities.Add((New-RooIndustriesCapabilityEntry $capability $resolvedAvailability)) | Out-Null
    }
}

$capabilityArray = @($capabilities.ToArray())
$familyGroups = @($capabilityArray | Group-Object family | Sort-Object Name)
$applyGroups = @($capabilityArray | Group-Object { [string]$_.apply.status } | Sort-Object Name)
$families = @($familyGroups | ForEach-Object {
    [pscustomobject]@{
        name = [string]$_.Name
        capabilityCount = [int]$_.Count
    }
})
$availableCount = @($capabilityArray | Where-Object { $_.resolvedAvailability.available -eq $true }).Count
$completedAtUtc = Get-RooIndustriesUtcStamp

$result = [pscustomobject]@{
    actionId = 'backend.capabilityRegistry.get'
    schemaVersion = 1
    productName = 'Roo Industries Optimization Suite'
    dryRun = $true
    risk = 'safe'
    requiresElevation = $false
    status = 'completed'
    correlationId = [guid]::NewGuid().ToString('N')
    startedAtUtc = $startedAtUtc
    completedAtUtc = $completedAtUtc
    generatedAtUtc = $completedAtUtc
    utilitiesRoot = $resolvedUtilitiesRoot
    families = $families
    capabilities = $capabilityArray
    summary = [pscustomobject]@{
        totalCapabilities = [int]$capabilityArray.Count
        byFamily = Convert-GroupsToCountObject $familyGroups
        byApplyStatus = Convert-GroupsToCountObject $applyGroups
        availableCount = [int]$availableCount
        unavailableCount = [int]($capabilityArray.Count - $availableCount)
    }
}

$json = $result | ConvertTo-Json -Depth 32
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $resolvedOutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "OutputPath parent does not exist: $parent"
    }
    Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
}

$json
