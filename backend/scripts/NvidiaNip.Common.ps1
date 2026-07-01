. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

$script:RooNvidiaNipProductName = 'Roo Industries Optimization Suite'

function Get-RooNvidiaNipCatalogPath {
    param([string]$CatalogPath)
    return Resolve-RooPath $CatalogPath (Join-Path $PSScriptRoot '..\catalogs\nvidia-profile-inspector-nip-catalog.json')
}

function Read-RooNvidiaNipCatalog {
    param([string]$CatalogPath)
    return Read-RooJsonFile (Get-RooNvidiaNipCatalogPath $CatalogPath)
}

function Get-RooNvidiaNipProfile {
    param(
        [object]$Catalog,
        [string]$ProfileId
    )
    foreach ($profile in @(Get-RooPropertyArray $Catalog 'profiles')) {
        if ([string](Get-RooPropertyValue $profile 'profileId' '') -eq $ProfileId) {
            return $profile
        }
    }
    throw "NVIDIA NIP profile not found: $ProfileId"
}

function ConvertTo-RooNvidiaSafeId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9\-]+','-').Trim('-'))
}

function ConvertTo-RooNvidiaQuotedArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Join-RooNvidiaCommandLine {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((ConvertTo-RooNvidiaQuotedArgument $Executable)) | Out-Null
    foreach ($arg in @($Arguments)) {
        $parts.Add((ConvertTo-RooNvidiaQuotedArgument ([string]$arg))) | Out-Null
    }
    return ($parts.ToArray() -join ' ')
}

function New-RooNvidiaNipCommand {
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
        commandLine = Join-RooNvidiaCommandLine $ExecutablePath @($arguments)
        commandFamily = 'nvidia-profile-inspector-cli'
        launchAllowedNow = $false
        processStarted = $false
    }
}

function Get-RooNvidiaHardwareEvidence {
    param([string]$HardwareInventoryPath)

    $summary = $null
    $source = 'live-readonly-driver-summary'
    if (-not [string]::IsNullOrWhiteSpace($HardwareInventoryPath)) {
        $summary = Read-RooJsonFile (Resolve-RooPath $HardwareInventoryPath $HardwareInventoryPath)
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
    foreach ($gpu in @(Get-RooPropertyArray $summary 'gpus')) {
        $vendor = [string](Get-RooPropertyValue $gpu 'vendor' '')
        $pnp = [string](Get-RooPropertyValue $gpu 'pnpDeviceId' '')
        if ($vendor -ieq 'NVIDIA' -or $pnp.IndexOf('PCI\VEN_10DE', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matched.Add([pscustomobject]@{
                name = Get-RooPropertyValue $gpu 'name' $null
                vendor = $vendor
                pnpDeviceId = $pnp
                driverVersion = Get-RooPropertyValue $gpu 'driverVersion' $null
            }) | Out-Null
        }
    }

    return [pscustomobject]@{
        source = $source
        hardwareInventoryPath = if ([string]::IsNullOrWhiteSpace($HardwareInventoryPath)) { $null } else { Resolve-RooPath $HardwareInventoryPath $HardwareInventoryPath }
        nvidiaGpuPresent = ($matched.Count -gt 0)
        matchedGpus = @($matched.ToArray())
    }
}

function New-RooNvidiaNipIssue {
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

function New-RooNvidiaNipGate {
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

function New-RooNvidiaNipRollbackManifest {
    param(
        [object]$Profile,
        [object]$ExportCommand,
        [string]$ExportPath
    )
    $profileId = [string](Get-RooPropertyValue $Profile 'profileId' '')
    return [pscustomobject]@{
        manifestId = 'nvidia-nip-rollback-' + (ConvertTo-RooNvidiaSafeId $profileId) + '-' + (Get-RooFileStamp)
        schemaVersion = 1
        productName = $script:RooNvidiaNipProductName
        actionId = 'drivers.nvidiaNip.rollbackManifest'
        profileId = $profileId
        profileName = [string](Get-RooPropertyValue $Profile 'name' '')
        createdAtUtc = Get-RooUtcStamp
        exportPath = $ExportPath
        exportCommand = $ExportCommand
        restoreActionId = 'drivers.nvidiaNip.restoreProfile'
        rollbackSupported = $true
        exportBeforeImportRequired = $true
        exportCompleted = $false
        nvpiExecutionAllowedNow = $false
    }
}

