. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooIndustriesNvidiaNipProductName = 'Roo Industries Optimization Suite'

function Get-RooIndustriesNvidiaNipCatalogPath {
    param([string]$CatalogPath)
    return Resolve-RooIndustriesPath $CatalogPath (Join-Path $PSScriptRoot '..\catalogs\nvidia-profile-inspector-nip-catalog.json')
}

function Read-RooIndustriesNvidiaNipCatalog {
    param([string]$CatalogPath)
    return Read-RooIndustriesJsonFile (Get-RooIndustriesNvidiaNipCatalogPath $CatalogPath)
}

function Get-RooIndustriesNvidiaNipProfile {
    param(
        [object]$Catalog,
        [string]$ProfileId
    )
    foreach ($profile in @(Get-RooIndustriesPropertyArray $Catalog 'profiles')) {
        if ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '') -eq $ProfileId) {
            return $profile
        }
    }
    throw "NVIDIA NIP profile not found: $ProfileId"
}

function Test-RooIndustriesNvidiaProfileId {
    param(
        [object]$Profile,
        [string]$SavedId
    )
    if ($SavedId -ceq [string](Get-RooIndustriesPropertyValue $Profile 'profileId' '')) { return $true }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($SavedId)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $digest = -join ($hash | ForEach-Object { $_.ToString('X2') })
    return @(Get-RooIndustriesPropertyArray $Profile 'formerProfileIdSha256') -contains $digest
}

function ConvertTo-RooIndustriesNvidiaSafeId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9\-]+','-').Trim('-'))
}

function ConvertTo-RooIndustriesNvidiaQuotedArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Join-RooIndustriesNvidiaCommandLine {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((ConvertTo-RooIndustriesNvidiaQuotedArgument $Executable)) | Out-Null
    foreach ($arg in @($Arguments)) {
        $parts.Add((ConvertTo-RooIndustriesNvidiaQuotedArgument ([string]$arg))) | Out-Null
    }
    return ($parts.ToArray() -join ' ')
}

function New-RooIndustriesNvidiaNipCommand {
    param(
        [string]$Operation,
        [string]$ExecutablePath,
        [string]$ProfileName,
        [string]$NipPath,
        [string]$ExportPath
    )

    $arguments = if ($Operation -eq 'export') {
        @('-exportProfile', $ProfileName, $ExportPath)
    } elseif ($Operation -eq 'import') {
        @('-importProfile', $NipPath)
    } else {
        throw "Unsupported NVIDIA NIP command operation: $Operation"
    }

    return [pscustomobject]@{
        operation = $Operation
        toolId = 'nvidia-profile-inspector'
        executablePath = $ExecutablePath
        arguments = @($arguments)
        commandLine = Join-RooIndustriesNvidiaCommandLine $ExecutablePath @($arguments)
        commandFamily = 'nvidia-profile-inspector-cli'
        launchAllowedNow = $false
        processStarted = $false
    }
}

function Get-RooIndustriesNvidiaHardwareEvidence {
    param([string]$HardwareInventoryPath)

    $summary = $null
    $source = 'live-readonly-driver-summary'
    if (-not [string]::IsNullOrWhiteSpace($HardwareInventoryPath)) {
        $summary = Read-RooIndustriesJsonFile (Resolve-RooIndustriesPath $HardwareInventoryPath $HardwareInventoryPath)
        $source = 'provided-hardware-inventory'
    } else {
        try {
            $summary = (& (Join-Path $PSScriptRoot 'Get-DriverHardwareSummary.ps1')) | ConvertFrom-Json
        } catch {
            $summary = $null
            $source = 'unavailable'
        }
    }

    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($gpu in @(Get-RooIndustriesPropertyArray $summary 'gpus')) {
        $vendor = [string](Get-RooIndustriesPropertyValue $gpu 'vendor' '')
        $pnp = [string](Get-RooIndustriesPropertyValue $gpu 'pnpDeviceId' '')
        if ($vendor -ieq 'NVIDIA' -or $pnp.IndexOf('PCI\VEN_10DE', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matched.Add([pscustomobject]@{
                name = Get-RooIndustriesPropertyValue $gpu 'name' $null
                vendor = $vendor
                pnpDeviceId = $pnp
                driverVersion = Get-RooIndustriesPropertyValue $gpu 'driverVersion' $null
            }) | Out-Null
        }
    }

    return [pscustomobject]@{
        source = $source
        hardwareInventoryPath = if ([string]::IsNullOrWhiteSpace($HardwareInventoryPath)) { $null } else { Resolve-RooIndustriesPath $HardwareInventoryPath $HardwareInventoryPath }
        nvidiaGpuPresent = ($matched.Count -gt 0)
        matchedGpus = @($matched.ToArray())
    }
}

function New-RooIndustriesNvidiaNipIssue {
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
        source = 'drivers.nvidiaNip'
        target = $Target
        blocking = $Blocking
        recommendedAction = $RecommendedAction
        details = $Details
    }
}

function New-RooIndustriesNvidiaNipGate {
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

function New-RooIndustriesNvidiaNipRollbackManifest {
    param(
        [object]$Profile,
        [object]$ExportCommand,
        [string]$ExportPath
    )
    $profileId = [string](Get-RooIndustriesPropertyValue $Profile 'profileId' '')
    return [pscustomobject]@{
        manifestId = 'nvidia-nip-rollback-' + (ConvertTo-RooIndustriesNvidiaSafeId $profileId) + '-' + (Get-RooIndustriesFileStamp)
        schemaVersion = 1
        productName = $script:RooIndustriesNvidiaNipProductName
        actionId = 'drivers.nvidiaNip.rollbackManifest'
        profileId = $profileId
        profileName = [string](Get-RooIndustriesPropertyValue $Profile 'name' '')
        createdAtUtc = Get-RooIndustriesUtcStamp
        exportPath = $ExportPath
        exportCommand = $ExportCommand
        restoreActionId = 'drivers.nvidiaNip.restoreProfile'
        rollbackSupported = $true
        exportBeforeImportRequired = $true
        exportCompleted = $false
        importAttempted = $false
        importCompleted = $false
        nvpiExecutionAllowedNow = $false
    }
}
