param(
    [string]$UtilitiesRoot = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RooUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Convert-ToCleanString {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Resolve-RooUtilitiesRoot {
    param([string]$Path)

    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:ROO_UTILITIES_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = 'C:\Users\serviroo\Desktop\Utilities'
    }

    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($candidate))
}

function Resolve-RooDetectionFilePath {
    param(
        [string]$Target,
        [string]$RepoRoot,
        [string]$ResolvedUtilitiesRoot
    )

    $resolved = $Target.Replace('{utilitiesRoot}', $ResolvedUtilitiesRoot)
    $resolved = [Environment]::ExpandEnvironmentVariables($resolved)
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $RepoRoot $resolved
    }

    return [System.IO.Path]::GetFullPath($resolved)
}

function Convert-RooRegistryTarget {
    param([string]$Target)

    $parts = $Target -split '\|', 2
    $path = $parts[0]
    $name = $null
    if ($parts.Count -gt 1) {
        $name = $parts[1]
    }
    if ($path -match '^(HKLM|HKCU|HKCR|HKU|HKCC)\\') {
        $path = $path -replace '^(HKLM|HKCU|HKCR|HKU|HKCC)\\', '$1:\'
    }

    return [pscustomobject]@{
        path = $path
        name = $name
    }
}

function Test-RooFileTargetIsTool {
    param([string]$Target)

    if ($Target -match '\{utilitiesRoot\}') { return $true }
    $expanded = [Environment]::ExpandEnvironmentVariables($Target)
    $extension = [System.IO.Path]::GetExtension($expanded)
    if ($extension -match '^\.(exe|msi|cmd|bat|ps1)$') { return $true }
    if ($expanded -match '^[A-Za-z]:\\Program Files\\' -and $extension -match '^\.(exe|dll)$') { return $true }
    return $false
}

function Get-RooFileEvidence {
    param([string]$ResolvedPath)

    $evidence = [ordered]@{
        path = $ResolvedPath
        exists = $false
        pathType = 'missing'
        sizeBytes = $null
        lastWriteTimeUtc = $null
        fileVersion = $null
        productVersion = $null
        companyName = $null
        productName = $null
        error = $null
    }

    try {
        $exists = Test-Path -LiteralPath $ResolvedPath
        $evidence.exists = [bool]$exists
        if (-not $exists) {
            return [pscustomobject]$evidence
        }

        $item = Get-Item -LiteralPath $ResolvedPath -ErrorAction Stop
        if ($item.PSIsContainer) {
            $evidence.pathType = 'container'
            $evidence.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            return [pscustomobject]$evidence
        }

        $version = $item.VersionInfo
        $evidence.path = $item.FullName
        $evidence.pathType = 'leaf'
        $evidence.sizeBytes = [uint64]$item.Length
        $evidence.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        $evidence.fileVersion = Convert-ToCleanString $version.FileVersion
        $evidence.productVersion = Convert-ToCleanString $version.ProductVersion
        $evidence.companyName = Convert-ToCleanString $version.CompanyName
        $evidence.productName = Convert-ToCleanString $version.ProductName
        return [pscustomobject]$evidence
    } catch {
        $evidence.error = $_.Exception.Message
        return [pscustomobject]$evidence
    }
}

function Get-RooGpuInventory {
    $controllers = @()
    $errorText = $null
    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        $errorText = $_.Exception.Message
    }

    return [pscustomobject]@{
        controllers = $controllers
        error = $errorText
    }
}

function Test-RooGpuVendor {
    param(
        [object]$Controller,
        [string]$Vendor
    )

    $name = [string](Get-PropertyValue $Controller 'Name' '')
    $pnpDeviceId = [string](Get-PropertyValue $Controller 'PNPDeviceID' '')
    $text = "$name $pnpDeviceId"

    switch ($Vendor) {
        'NVIDIA' { return ($text -match 'NVIDIA|VEN_10DE') }
        'AMD' { return ($text -match 'AMD|VEN_1002|Advanced Micro Devices') }
        'Intel' { return ($text -match 'Intel|VEN_8086') }
        default { return $false }
    }
}

function Resolve-RooDetectionRule {
    param(
        [object]$Rule,
        [string]$RepoRoot,
        [string]$ResolvedUtilitiesRoot,
        [object]$GpuInventory
    )

    $method = [string](Get-PropertyValue $Rule 'method' '')
    $target = [string](Get-PropertyValue $Rule 'target' '')
    $resolvedTarget = $target
    $passed = $false
    $evidence = $null
    $reason = $null

    switch ($method) {
        'builtin' {
            $passed = $true
            $evidence = [pscustomobject]@{
                target = $target
                assumedPresent = $true
            }
        }
        'file-exists' {
            try {
                $resolvedTarget = Resolve-RooDetectionFilePath $target $RepoRoot $ResolvedUtilitiesRoot
                $evidence = Get-RooFileEvidence $resolvedTarget
                $passed = [bool]$evidence.exists
                $repoPrefix = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
                if ($resolvedTarget.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $resolvedTarget.Substring($repoPrefix.Length).Replace('\', '/')
                    $resolvedTarget = $relative
                    $evidence.path = $relative
                }
            } catch {
                $evidence = [pscustomobject]@{
                    path = $resolvedTarget
                    exists = $false
                    error = $_.Exception.Message
                }
                $passed = $false
            }
        }
        'registry-key' {
            $registry = Convert-RooRegistryTarget $target
            $resolvedTarget = $registry.path
            $exists = $false
            $errorText = $null
            try {
                $exists = Test-Path -LiteralPath $registry.path
            } catch {
                $errorText = $_.Exception.Message
            }
            $passed = [bool]$exists
            $evidence = [pscustomobject]@{
                path = $registry.path
                exists = [bool]$exists
                error = $errorText
            }
        }
        'registry-value' {
            $registry = Convert-RooRegistryTarget $target
            $resolvedTarget = if ([string]::IsNullOrWhiteSpace($registry.name)) { $registry.path } else { "$($registry.path)|$($registry.name)" }
            $keyExists = $false
            $valuePresent = $false
            $valueText = $null
            $errorText = $null
            try {
                $keyExists = Test-Path -LiteralPath $registry.path
                if ($keyExists -and -not [string]::IsNullOrWhiteSpace($registry.name)) {
                    $item = Get-ItemProperty -LiteralPath $registry.path -Name $registry.name -ErrorAction Stop
                    $property = $item.PSObject.Properties[$registry.name]
                    $valuePresent = ($null -ne $property)
                    if ($valuePresent) {
                        $valueText = Convert-ToCleanString $property.Value
                    }
                } elseif ($keyExists) {
                    $valuePresent = $true
                }
            } catch {
                $errorText = $_.Exception.Message
            }
            $passed = [bool]($keyExists -and $valuePresent)
            $evidence = [pscustomobject]@{
                path = $registry.path
                valueName = $registry.name
                keyExists = [bool]$keyExists
                valuePresent = [bool]$valuePresent
                value = $valueText
                error = $errorText
            }
        }
        'service-exists' {
            $service = $null
            $errorText = $null
            try {
                $service = Get-Service -Name $target -ErrorAction SilentlyContinue | Select-Object -First 1
            } catch {
                $errorText = $_.Exception.Message
            }
            $passed = ($null -ne $service)
            $evidence = [pscustomobject]@{
                serviceName = $target
                exists = [bool]$passed
                displayName = if ($service) { [string]$service.DisplayName } else { $null }
                status = if ($service) { [string]$service.Status } else { $null }
                error = $errorText
            }
        }
        'command-on-path' {
            $command = $null
            $errorText = $null
            try {
                $command = Get-Command -Name $target -ErrorAction SilentlyContinue | Select-Object -First 1
            } catch {
                $errorText = $_.Exception.Message
            }
            $passed = ($null -ne $command)
            $source = if ($command) { Convert-ToCleanString (Get-PropertyValue $command 'Source' $null) } else { $null }
            $version = $null
            if (-not [string]::IsNullOrWhiteSpace($source) -and (Test-Path -LiteralPath $source -PathType Leaf)) {
                try {
                    $version = Convert-ToCleanString (Get-Item -LiteralPath $source).VersionInfo.FileVersion
                } catch {
                    $version = $null
                }
            }
            $resolvedTarget = if ([string]::IsNullOrWhiteSpace($source)) { $target } else { $source }
            $evidence = [pscustomobject]@{
                command = $target
                found = [bool]$passed
                source = $source
                commandType = if ($command) { [string]$command.CommandType } else { $null }
                fileVersion = $version
                error = $errorText
            }
        }
        'hardware-gpu-vendor' {
            $controllers = @($GpuInventory.controllers)
            $matchedControllers = @($controllers | Where-Object { Test-RooGpuVendor $_ $target })
            $passed = ($matchedControllers.Count -gt 0)
            $evidenceControllers = @($controllers | ForEach-Object {
                [pscustomobject]@{
                    name = Convert-ToCleanString (Get-PropertyValue $_ 'Name' $null)
                    pnpDeviceId = Convert-ToCleanString (Get-PropertyValue $_ 'PNPDeviceID' $null)
                    matched = [bool](Test-RooGpuVendor $_ $target)
                }
            })
            $evidence = [pscustomobject]@{
                requestedVendor = $target
                matched = [bool]$passed
                controllers = $evidenceControllers
                error = $GpuInventory.error
            }
        }
        'windows-feature' {
            try {
                $featureCommand = Get-Command -Name Get-WindowsOptionalFeature -ErrorAction SilentlyContinue
                if ($null -eq $featureCommand) {
                    throw 'Get-WindowsOptionalFeature command not available'
                }

                $feature = Get-WindowsOptionalFeature -Online -FeatureName $target -ErrorAction Stop
                $passed = ($null -ne $feature)
                $evidence = [pscustomobject]@{
                    featureName = $target
                    found = [bool]$passed
                    state = if ($feature) { [string](Get-PropertyValue $feature 'State' 'unknown') } else { $null }
                    restartNeeded = if ($feature) { Convert-ToCleanString (Get-PropertyValue $feature 'RestartNeeded' $null) } else { $null }
                    error = $null
                }
            } catch {
                $passed = $false
                $message = $_.Exception.Message
                $reason = if ($message -match 'elevation|access is denied') {
                    'requires-admin-token: Get-WindowsOptionalFeature -Online needs an administrators-group token'
                } else {
                    "windows-feature-query-failed: $message"
                }
                $evidence = [pscustomobject]@{
                    featureName = $target
                    found = $false
                    state = $null
                    restartNeeded = $null
                    error = $message
                }
            }
        }
        default {
            $passed = $false
            $reason = "unsupported-detection-method: $method"
            $evidence = [pscustomobject]@{
                target = $target
                error = $reason
            }
        }
    }

    return [pscustomobject]@{
        method = $method
        target = $target
        resolvedTarget = $resolvedTarget
        passed = [bool]$passed
        evidence = $evidence
        reason = $reason
    }
}

function Get-RooUnavailableReason {
    param(
        [object]$Capability,
        [object[]]$CheckedRules
    )

    $failedRules = @($CheckedRules | Where-Object { $_.passed -ne $true })
    if ($failedRules.Count -eq 0) { return $null }

    $hardwareFailure = @($failedRules | Where-Object { [string]$_.method -eq 'hardware-gpu-vendor' }) | Select-Object -First 1
    if ($hardwareFailure) { return 'hardware-not-present' }

    $toolFileFailure = @($failedRules | Where-Object {
        [string]$_.method -eq 'file-exists' -and (Test-RooFileTargetIsTool ([string]$_.target))
    }) | Select-Object -First 1
    if ($toolFileFailure) { return 'tool-not-present' }

    $windowsFeatureFailure = @($failedRules | Where-Object { [string]$_.method -eq 'windows-feature' -and -not [string]::IsNullOrWhiteSpace([string]$_.reason) }) | Select-Object -First 1
    if ($windowsFeatureFailure) { return [string]$windowsFeatureFailure.reason }

    $staticReason = Get-PropertyValue $Capability 'unavailableReason' $null
    if ($null -ne $staticReason -and -not [string]::IsNullOrWhiteSpace([string]$staticReason)) {
        return [string]$staticReason
    }

    $firstFailure = $failedRules | Select-Object -First 1
    $failureTarget = Convert-ToCleanString (Get-PropertyValue $firstFailure 'resolvedTarget' $null)
    if ([string]::IsNullOrWhiteSpace($failureTarget)) {
        $failureTarget = [string](Get-PropertyValue $firstFailure 'target' '')
    }
    return "requirement-not-met: $([string]$firstFailure.method) $failureTarget"
}

function New-RooCapabilityEntry {
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

$startedAtUtc = Get-RooUtcStamp
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$capabilityRoot = Join-Path $repoRoot 'backend\capabilities'
$resolvedUtilitiesRoot = Resolve-RooUtilitiesRoot $UtilitiesRoot
$gpuInventory = Get-RooGpuInventory

$fragments = @(Get-ChildItem -LiteralPath $capabilityRoot -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
})

$capabilities = New-Object System.Collections.Generic.List[object]
foreach ($fragment in $fragments) {
    foreach ($capability in @($fragment.capabilities)) {
        $checkedRules = @()
        foreach ($rule in @($capability.availability.detection)) {
            $checkedRules += Resolve-RooDetectionRule $rule $repoRoot $resolvedUtilitiesRoot $gpuInventory
        }

        $available = ($checkedRules.Count -gt 0 -and @($checkedRules | Where-Object { $_.passed -ne $true }).Count -eq 0)
        $unavailableReason = Get-RooUnavailableReason $capability $checkedRules
        $resolvedAvailability = [pscustomobject]@{
            available = [bool]$available
            checkedRules = @($checkedRules)
            unavailableReason = $unavailableReason
        }

        $capabilities.Add((New-RooCapabilityEntry $capability $resolvedAvailability)) | Out-Null
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
$completedAtUtc = Get-RooUtcStamp

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
