$ErrorActionPreference = 'Stop'

function Read-Spec {
    param([scriptblock]$Block)
    try {
        $value = & $Block
        if ([string]::IsNullOrWhiteSpace([string]$value)) { return $null }
        return ([string]$value).Trim()
    } catch {
        return $null
    }
}

function Format-GB {
    param([double]$Bytes)
    return ([math]::Round($Bytes / 1GB)).ToString([Globalization.CultureInfo]::InvariantCulture) + ' GB'
}

$videoControllers = @(try { Get-CimInstance -ClassName Win32_VideoController -Property Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate } catch { })

$windows = Read-Spec {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption,BuildNumber,OSArchitecture
    if (-not $os.Caption) { return }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $release = (Get-ItemProperty -LiteralPath $key -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
    $revision = (Get-ItemProperty -LiteralPath $key -Name UBR -ErrorAction SilentlyContinue).UBR
    $build = if ($null -ne $revision) { "$($os.BuildNumber).$revision" } else { "$($os.BuildNumber)" }
    (@($os.Caption, $release, "build $build", $os.OSArchitecture) | Where-Object { $_ }) -join ' '
}

$cpu = Read-Spec {
    $processor = Get-CimInstance -ClassName Win32_Processor -Property Name,NumberOfCores,NumberOfLogicalProcessors | Select-Object -First 1
    "$($processor.Name.Trim()) ($($processor.NumberOfCores) cores, $($processor.NumberOfLogicalProcessors) threads)"
}

$gpu = Read-Spec {
    (@($videoControllers | Where-Object { $_.Name } | ForEach-Object {
        if ($_.DriverVersion) { "$($_.Name) (driver $($_.DriverVersion))" } else { $_.Name }
    })) -join '; '
}

$display = Read-Spec {
    $active = $videoControllers | Where-Object { $_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution } | Select-Object -First 1
    if (-not $active) { return }
    $text = "$($active.CurrentHorizontalResolution) x $($active.CurrentVerticalResolution)"
    if ($active.CurrentRefreshRate) { $text += " at $($active.CurrentRefreshRate) Hz" }
    $text
}

$ram = Read-Spec {
    $modules = @(Get-CimInstance -ClassName Win32_PhysicalMemory -Property Capacity,ConfiguredClockSpeed,Speed)
    $total = ($modules | Measure-Object -Property Capacity -Sum).Sum
    if (-not $total) { $total = [double](Get-CimInstance -ClassName Win32_OperatingSystem -Property TotalVisibleMemorySize).TotalVisibleMemorySize * 1KB }
    $speed = ($modules | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Measure-Object -Maximum).Maximum
    $text = Format-GB $total
    if ($modules.Count -gt 0) { $text += " ($($modules.Count) sticks" + $(if ($speed) { ", $speed MT/s" } else { '' }) + ')' }
    $text
}

$motherboard = Read-Spec {
    $board = Get-CimInstance -ClassName Win32_BaseBoard -Property Manufacturer,Product | Select-Object -First 1
    (@($board.Manufacturer, $board.Product) | Where-Object { $_ }) -join ' '
}

$bios = Read-Spec {
    $firmware = Get-CimInstance -ClassName Win32_BIOS -Property Manufacturer,SMBIOSBIOSVersion,ReleaseDate | Select-Object -First 1
    if (-not $firmware.SMBIOSBIOSVersion) { return }
    $details = @($firmware.Manufacturer)
    if ($firmware.ReleaseDate) { $details += ([datetime]$firmware.ReleaseDate).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    "$($firmware.SMBIOSBIOSVersion) ($((@($details | Where-Object { $_ })) -join ', '))"
}

$drive = Read-Spec {
    $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Property DeviceID,Size,FreeSpace -Filter "DeviceID='$env:SystemDrive'"
    $kind = $null
    try {
        $link = Get-CimInstance -ClassName Win32_LogicalDiskToPartition -Property Antecedent,Dependent | Where-Object { $_.Dependent.DeviceID -eq $env:SystemDrive } | Select-Object -First 1
        if ($link -and [string]$link.Antecedent.DeviceID -match 'Disk #(\d+)') {
            $index = [int]$Matches[1]
            $model = (Get-CimInstance -ClassName Win32_DiskDrive -Property Index,Model -Filter "Index=$index" | Select-Object -First 1).Model
            $media = $null
            try {
                $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $media = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Get-BugReportDiskKind.ps1') -Index $index 2>$null | Select-Object -Last 1
                if ($LASTEXITCODE -ne 0) { $media = $null }
            } catch { }
            $kind = (@($model, $media) | Where-Object { $_ }) -join ', '
        }
    } catch { }
    $space = if ($logical.Size) { "$(Format-GB $logical.FreeSpace) free of $(Format-GB $logical.Size)" } else { $null }
    (@($kind, $space) | Where-Object { $_ }) -join ', '
}

[pscustomobject]@{
    windows = $windows
    cpu = $cpu
    gpu = $gpu
    ram = $ram
    motherboard = $motherboard
    bios = $bios
    drive = $drive
    display = $display
} | ConvertTo-Json -Compress
