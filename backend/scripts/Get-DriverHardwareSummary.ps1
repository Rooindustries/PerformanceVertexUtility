$ErrorActionPreference = 'Stop'

function Convert-ToUInt64OrNull {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    try { return [uint64]$Value } catch { return $null }
}

function Convert-CimDate {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    try {
        return ([System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToString('yyyy-MM-dd')
    } catch {
        return [string]$Value
    }
}

function Get-VendorFromText {
    param([string]$Text)
    $t = ($Text -as [string]).ToLowerInvariant()
    if ($t -match 'nvidia|ven_10de') { return 'NVIDIA' }
    if ($t -match 'intel|ven_8086') { return 'Intel' }
    if ($t -match 'amd|advanced micro devices|ven_1002') { return 'AMD' }
    if ($t -match 'realtek|ven_10ec') { return 'Realtek' }
    if ($t -match 'qualcomm|atheros') { return 'Qualcomm' }
    if ($t -match 'tailscale') { return 'Tailscale Inc.' }
    return 'Unknown'
}

$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$memoryModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
$networkAdapters = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalAdapter -or $_.Name -match 'Tailscale|WireGuard|VPN|Wi-Fi|Ethernet' })
$drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceClass -in @('DISPLAY','NET','MEDIA','HDC','SYSTEM') })

$gpuItems = @($gpus | ForEach-Object {
    [pscustomobject]@{
        name = $_.Name
        vendor = Get-VendorFromText ($_.Name + ' ' + $_.PNPDeviceID)
        pnpDeviceId = $_.PNPDeviceID
        adapterRamBytes = Convert-ToUInt64OrNull $_.AdapterRAM
        driverVersion = $_.DriverVersion
        driverDate = Convert-CimDate $_.DriverDate
    }
})

$networkItems = @($networkAdapters | ForEach-Object {
    $vendor = Get-VendorFromText ($_.Name + ' ' + $_.PNPDeviceID)
    $protected = ($_.Name -match 'Wi-Fi|Wireless|Tailscale|WireGuard|VPN')
    [pscustomobject]@{
        name = $_.Name
        vendor = $vendor
        pnpDeviceId = $_.PNPDeviceID
        driverVersion = $null
        protected = [bool]$protected
        reason = if ($protected) { 'Network adapters and VPN interfaces require manual review by default' } else { $null }
    }
})

$driverItems = @($drivers | ForEach-Object {
    $hardwareIds = @()
    if ($_.HardWareID) {
        if ($_.HardWareID -is [array]) { $hardwareIds = @($_.HardWareID) } else { $hardwareIds = @([string]$_.HardWareID) }
    }
    [pscustomobject]@{
        driverId = 'driver:' + (([string]$_.DeviceID).ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
        deviceName = $_.DeviceName
        vendor = Get-VendorFromText ($_.Manufacturer + ' ' + $_.DeviceName + ' ' + $_.DeviceID)
        deviceClass = $_.DeviceClass
        hardwareIds = $hardwareIds
        version = $_.DriverVersion
        date = Convert-CimDate $_.DriverDate
        provider = $_.DriverProviderName
        infName = $_.InfName
        signed = if ($null -ne $_.IsSigned) { [bool]$_.IsSigned } else { $null }
        status = $_.Status
    }
})

[pscustomobject]@{
    schemaVersion = 1
    productName = 'Roo Industries Optimization Suite'
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    machine = [pscustomobject]@{
        manufacturer = if ($cs) { $cs.Manufacturer } else { $null }
        model = if ($cs) { $cs.Model } else { $null }
        systemType = if ($cs) { $cs.SystemType } else { $null }
        osCaption = if ($os) { $os.Caption } else { $null }
        osBuild = if ($os) { $os.BuildNumber } else { $null }
    }
    cpu = [pscustomobject]@{
        name = if ($cpu) { $cpu.Name } else { $null }
        manufacturer = if ($cpu) { $cpu.Manufacturer } else { $null }
        cores = if ($cpu) { [int]$cpu.NumberOfCores } else { $null }
        logicalProcessors = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { $null }
    }
    memory = [pscustomobject]@{
        totalPhysicalBytes = if ($cs) { [uint64]$cs.TotalPhysicalMemory } else { $null }
        moduleCount = $memoryModules.Count
        modules = @($memoryModules | ForEach-Object {
            [pscustomobject]@{
                capacityBytes = Convert-ToUInt64OrNull $_.Capacity
                speedMhz = $_.Speed
                manufacturer = $_.Manufacturer
                partNumber = $_.PartNumber
            }
        })
    }
    gpus = $gpuItems
    networkAdapters = $networkItems
    installedDrivers = $driverItems
} | ConvertTo-Json -Depth 8
