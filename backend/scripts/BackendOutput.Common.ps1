$script:RooIndustriesProcessProductName = 'Roo Industries Optimization Suite'

function ConvertTo-RooIndustriesWindowsArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Join-RooIndustriesWindowsArguments {
    param([string[]]$Arguments)
    return (@($Arguments | ForEach-Object { ConvertTo-RooIndustriesWindowsArgument $_ }) -join ' ')
}

function Get-RooIndustriesUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-RooIndustriesFileStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
}

function Resolve-RooIndustriesPath {
    param(
        [string]$Path,
        [string]$DefaultPath
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [System.IO.Path]::GetFullPath($DefaultPath)
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Read-RooIndustriesJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Ensure-RooIndustriesDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RooIndustriesJsonOutput {
    param(
        [object]$Value,
        [string]$OutputPath
    )
    $json = $Value | ConvertTo-Json -Depth 24
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = Resolve-RooIndustriesPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        Ensure-RooIndustriesDirectory (Split-Path $resolved -Parent)
        $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    }
    return $json
}

function Get-RooIndustriesArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-RooIndustriesPropertyArray {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @() }
    return @(Get-RooIndustriesArray $prop.Value)
}

function Get-RooIndustriesPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )
    if ($null -eq $Object) { return $DefaultValue }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $DefaultValue }
    if ($null -eq $prop.Value) { return $DefaultValue }
    return $prop.Value
}

function New-RooIndustriesIssue {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Severity = 'warning',
        [string]$Source = 'performance.profile',
        [string]$Target = $null,
        [bool]$Blocking = $false,
        [string]$RecommendedAction = $null,
        [object]$Details = $null
    )
    return [pscustomobject]@{
        code = $Code
        message = $Message
        severity = $Severity
        source = $Source
        target = $Target
        blocking = $Blocking
        recommendedAction = $RecommendedAction
        details = $Details
    }
}

function New-RooIndustriesLog {
    param(
        [string]$Message,
        [string]$Level = 'info'
    )
    return [pscustomobject]@{
        timestampUtc = Get-RooIndustriesUtcStamp
        level = $Level
        message = $Message
    }
}
