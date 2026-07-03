param(
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RooUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function New-RooLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooUtcStamp
        level = $Level
        message = $Message
    }
}

function Write-RooJsonOutput {
    param(
        [object]$Value,
        [string]$Path
    )
    $json = $Value | ConvertTo-Json -Depth 10
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $json
        return
    }
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-RegistryValueFact {
    param(
        [string]$Path,
        [string]$Name
    )

    $exists = $false
    $valuePresent = $false
    $value = $null
    $kind = $null
    $errorText = $null

    try {
        $exists = Test-Path -LiteralPath $Path
        if ($exists) {
            $property = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            $valueProperty = $property.PSObject.Properties[$Name]
            if ($null -ne $valueProperty) {
                $valuePresent = $true
                $value = $valueProperty.Value
            }
            try {
                $key = Get-Item -LiteralPath $Path -ErrorAction Stop
                $kind = [string]$key.GetValueKind($Name)
            } catch {
                $kind = $null
            }
        }
    } catch {
        $errorText = $_.Exception.Message
    }

    return [pscustomobject]@{
        path = $Path
        name = $Name
        exists = $exists
        valuePresent = $valuePresent
        value = $value
        kind = $kind
        error = $errorText
    }
}

function Get-ServiceFact {
    param([string]$Name)

    $service = $null
    $errorText = $null
    try {
        $escapedName = $Name.Replace("'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop
    } catch {
        $errorText = $_.Exception.Message
    }

    return [pscustomobject]@{
        name = $Name
        exists = ($null -ne $service)
        displayName = if ($null -ne $service) { [string]$service.DisplayName } else { $null }
        state = if ($null -ne $service) { [string]$service.State } else { $null }
        startMode = if ($null -ne $service) { [string]$service.StartMode } else { $null }
        processId = if ($null -ne $service) { $service.ProcessId } else { $null }
        error = $errorText
    }
}

function Get-CommandFact {
    param([string]$Name)

    $command = $null
    $version = $null
    $source = $null
    $errorText = $null
    try {
        $command = Get-Command -Name $Name -ErrorAction Stop
        $source = [string]$command.Source
        if (-not [string]::IsNullOrWhiteSpace($source) -and (Test-Path -LiteralPath $source -PathType Leaf)) {
            $versionInfo = (Get-Item -LiteralPath $source -ErrorAction Stop).VersionInfo
            if ($null -ne $versionInfo) {
                $version = [string]$versionInfo.FileVersion
            }
        }
    } catch {
        $errorText = $_.Exception.Message
    }

    return [pscustomobject]@{
        name = $Name
        available = ($null -ne $command)
        source = $source
        fileVersion = $version
        error = $errorText
    }
}

function Get-FileFact {
    param([string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $absolute = $expanded
    try {
        if (-not [System.IO.Path]::IsPathRooted($absolute)) {
            $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
            $absolute = Join-Path $repoRoot.Path $absolute
        }
        $absolute = [System.IO.Path]::GetFullPath($absolute)
    } catch {
        $absolute = $expanded
    }

    return [pscustomobject]@{
        path = $Path
        resolvedPath = $absolute
        exists = (Test-Path -LiteralPath $absolute)
    }
}

$correlationId = [guid]::NewGuid().ToString()
$startedAtUtc = Get-RooUtcStamp

try {
    $registryTargets = @(
        [pscustomobject]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; name = 'AppCaptureEnabled' },
        [pscustomobject]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; name = 'AudioCaptureEnabled' },
        [pscustomobject]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; name = 'CursorCaptureEnabled' },
        [pscustomobject]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; name = 'MicrophoneCaptureEnabled' },
        [pscustomobject]@{ path = 'HKCU:\System\GameConfigStore'; name = 'GameDVR_Enabled' },
        [pscustomobject]@{ path = 'HKCU:\Software\Microsoft\GameBar'; name = 'ShowStartupPanel' },
        [pscustomobject]@{ path = 'HKCU:\Software\Microsoft\GameBar'; name = 'UseNexusForGameBarEnabled' },
        [pscustomobject]@{ path = 'HKLM:\SYSTEM\CurrentControlSet\Control'; name = 'SvcHostSplitThresholdInKB' },
        [pscustomobject]@{ path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; name = 'NetworkThrottlingIndex' }
    )

    $serviceTargets = @(
        'WerSvc',
        'PcaSvc',
        'TrkWks',
        'InventorySvc',
        'MapsBroker',
        'diagsvc',
        'Dnscache'
    )

    $fileTargets = @(
        'backend/native/StandbyMemoryHelper/RooStandbyMemoryHelper.cs',
        '%LOCALAPPDATA%\D3DSCache',
        '%LOCALAPPDATA%\NVIDIA'
    )

    $registryFacts = @($registryTargets | ForEach-Object { Get-RegistryValueFact -Path $_.path -Name $_.name })
    $serviceFacts = @($serviceTargets | ForEach-Object { Get-ServiceFact -Name $_ })
    $fileFacts = @($fileTargets | ForEach-Object { Get-FileFact -Path $_ })
    $commandFacts = @('powercfg.exe', 'dism.exe', 'sfc.exe', 'bcdedit.exe') | ForEach-Object { Get-CommandFact -Name $_ }

    $adapterError = $null
    $networkAdapters = @()
    try {
        $networkAdapters = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                description = [string]$_.Description
                dhcpEnabled = [bool]$_.DHCPEnabled
                dnsServerSearchOrder = @($_.DNSServerSearchOrder)
                ipAddressCount = @($_.IPAddress).Count
            }
        })
    } catch {
        $adapterError = $_.Exception.Message
    }

    $gpuError = $null
    $gpus = @()
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.Name
                adapterCompatibility = [string]$_.AdapterCompatibility
                driverVersion = [string]$_.DriverVersion
                pnpDeviceId = [string]$_.PNPDeviceID
            }
        })
    } catch {
        $gpuError = $_.Exception.Message
    }

    $result = [pscustomobject]@{
        actionId = 'systemOptimizations.facts'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        correlationId = $correlationId
        startedAtUtc = $startedAtUtc
        capturedAtUtc = Get-RooUtcStamp
        completedAtUtc = Get-RooUtcStamp
        dryRun = $true
        status = 'completed'
        facts = [pscustomobject]@{
            registryValues = $registryFacts
            services = $serviceFacts
            files = $fileFacts
            commands = @($commandFacts)
            networkAdapters = $networkAdapters
            networkAdapterError = $adapterError
            gpus = $gpus
            gpuError = $gpuError
            windowsFeatureProbe = [pscustomobject]@{
                featureNames = @('Microsoft-Hyper-V-All', 'NetFx3', 'Windows-Subsystem-Linux')
                dismAvailable = [bool](@($commandFacts | Where-Object { $_.name -eq 'dism.exe' -and $_.available -eq $true }).Count -gt 0)
                dismExecuted = $false
            }
        }
        summary = [pscustomobject]@{
            registryTargetCount = $registryFacts.Count
            serviceTargetCount = $serviceFacts.Count
            fileTargetCount = $fileFacts.Count
            commandTargetCount = @($commandFacts).Count
            ipEnabledNetworkAdapterCount = $networkAdapters.Count
            gpuCount = $gpus.Count
            willChangeSystem = $false
            willWriteRegistry = $false
            willEditServices = $false
            willLaunchExternalUtility = $false
            willRunDism = $false
        }
        warnings = @()
        errors = @()
        logs = @((New-RooLog 'System optimization facts collected without system changes.'))
    }

    Write-RooJsonOutput -Value $result -Path $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'systemOptimizations.facts'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        correlationId = $correlationId
        startedAtUtc = $startedAtUtc
        capturedAtUtc = Get-RooUtcStamp
        completedAtUtc = Get-RooUtcStamp
        dryRun = $true
        status = 'failed'
        facts = $null
        summary = [pscustomobject]@{
            willChangeSystem = $false
            willWriteRegistry = $false
            willEditServices = $false
            willLaunchExternalUtility = $false
            willRunDism = $false
        }
        warnings = @()
        errors = @([pscustomobject]@{
            code = 'SYSTEM_OPTIMIZATION_FACTS_FAILED'
            message = $_.Exception.Message
            severity = 'error'
            recoverable = $true
            nextStep = 'Check read-only registry, service, CIM, and file access.'
        })
        logs = @((New-RooLog 'System optimization facts collection failed.' 'error'))
    }
    Write-RooJsonOutput -Value $errorResult -Path $OutputPath
    exit 1
}
