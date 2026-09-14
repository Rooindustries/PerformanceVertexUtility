param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Get-CommandInfo {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    return [pscustomobject]@{
        name = $cmd.Name
        source = $cmd.Source
        version = if ($cmd.Version) { [string]$cmd.Version } else { $null }
    }
}

function Add-DotnetCandidatePath {
    param(
        [System.Collections.Generic.List[object]]$Candidates,
        [hashtable]$Seen,
        [string]$Path,
        [string]$SourceKind
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $key = $fullPath.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) {
        $Seen[$key].sourceKinds.Add($SourceKind) | Out-Null
        return
    }
    $candidate = [pscustomobject]@{
        path = $fullPath
        sourceKinds = New-Object System.Collections.Generic.List[string]
    }
    $candidate.sourceKinds.Add($SourceKind) | Out-Null
    $Seen[$key] = $candidate
    $Candidates.Add($candidate) | Out-Null
}

function Get-DotnetCandidatePaths {
    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    Add-DotnetCandidatePath $candidates $seen $env:ROO_DOTNET_EXE 'configured'
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Add-DotnetCandidatePath $candidates $seen (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe') 'user-local'
    }

    foreach ($cmd in @(Get-Command dotnet.exe -All -ErrorAction SilentlyContinue)) {
        Add-DotnetCandidatePath $candidates $seen $cmd.Source 'get-command'
    }

    foreach ($pathEntry in @([string]$env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pathEntry)) { continue }
        Add-DotnetCandidatePath $candidates $seen (Join-Path $pathEntry 'dotnet.exe') 'path'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Add-DotnetCandidatePath $candidates $seen (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe') 'user-local'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-DotnetCandidatePath $candidates $seen (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe') 'program-files'
    }

    return @($candidates.ToArray() | Sort-Object path)
}

function Convert-DotnetVersion {
    param([string]$VersionText)
    try { return [version]$VersionText } catch { return [version]'0.0.0' }
}

function Get-DotnetCandidateInfo {
    param([object]$Candidate)

    $exists = Test-Path -LiteralPath $Candidate.path -PathType Leaf
    $sdkLines = @()
    $sdkVersions = @()
    $highestSdkVersion = $null
    $hostVersion = $null
    $rid = $null
    $probeError = $null

    if ($exists) {
        try {
            $sdkLines = @(& $Candidate.path --list-sdks 2>$null)
            foreach ($line in $sdkLines) {
                if ($line -match '^([0-9]+\.[0-9]+\.[0-9]+)') {
                    $sdkVersions += $matches[1]
                }
            }
            if ($sdkVersions.Count -gt 0) {
                $highestSdkVersion = @($sdkVersions | Sort-Object { Convert-DotnetVersion $_ } -Descending | Select-Object -First 1)[0]
            }
            $infoLines = @(& $Candidate.path --info 2>$null)
            foreach ($line in $infoLines) {
                if ($null -eq $hostVersion -and $line -match '^\s*Version:\s+(.+)$') { $hostVersion = $matches[1].Trim() }
                if ($null -eq $rid -and $line -match '^\s*RID:\s+(.+)$') { $rid = $matches[1].Trim() }
            }
        } catch {
            $probeError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        path = $Candidate.path
        sourceKinds = @($Candidate.sourceKinds.ToArray() | Sort-Object -Unique)
        exists = [bool]$exists
        hasSdks = $sdkVersions.Count -gt 0
        sdkCount = $sdkVersions.Count
        sdkVersions = @($sdkVersions)
        highestSdkVersion = $highestSdkVersion
        hostVersion = $hostVersion
        rid = $rid
        probeError = $probeError
    }
}

function Get-DotnetCandidateSortKey {
    param([object]$Candidate)
    $version = Convert-DotnetVersion ([string]$Candidate.highestSdkVersion)
    $userLocalRank = if (@($Candidate.sourceKinds) -contains 'user-local') { 1 } else { 0 }
    return [pscustomobject]@{
        version = $version
        userLocalRank = $userLocalRank
        path = [string]$Candidate.path
    }
}

try {
    $framework64Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $frameworkCsc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    $cscPath = if (Test-Path -LiteralPath $framework64Csc) { $framework64Csc } elseif (Test-Path -LiteralPath $frameworkCsc) { $frameworkCsc } else { $null }

    $dotnetCandidates = @(Get-DotnetCandidatePaths | ForEach-Object { Get-DotnetCandidateInfo $_ })
    $sdkCandidates = @($dotnetCandidates | Where-Object { $_.exists -and $_.hasSdks })
    $selectedSdkHost = $null
    if ($sdkCandidates.Count -gt 0) {
        $selectedSdkHost = @($sdkCandidates | Sort-Object `
            @{ Expression = { (Get-DotnetCandidateSortKey $_).version }; Descending = $true }, `
            @{ Expression = { (Get-DotnetCandidateSortKey $_).userLocalRank }; Descending = $true }, `
            @{ Expression = { (Get-DotnetCandidateSortKey $_).path }; Descending = $false } |
            Select-Object -First 1)[0]
    }

    $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
    $vsCl = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio' -Recurse -Filter cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $vsX86Cl = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio' -Recurse -Filter cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $clang = Get-CommandInfo 'clang.exe'
    $clangCl = Get-CommandInfo 'clang-cl.exe'
    $gcc = Get-CommandInfo 'gcc.exe'
    $gpp = Get-CommandInfo 'g++.exe'
    $cxxWin32Available = ($null -ne $clCommand) -or ($null -ne $vsCl) -or ($null -ne $vsX86Cl) -or ($null -ne $clangCl) -or ($null -ne $clang) -or ($null -ne $gcc) -or ($null -ne $gpp)
    $msvcLinkerAvailable = ($null -ne $clCommand) -or ($null -ne $vsCl) -or ($null -ne $vsX86Cl)
    $dotnetSdkAvailable = $null -ne $selectedSdkHost
    $dotnetNativeAotAvailable = [bool]$dotnetSdkAvailable -and [bool]$msvcLinkerAvailable
    $workerClassification = if ($cscPath) { 'managed-csc' } else { 'none' }
    $selectedApproach = switch ($workerClassification) {
        'managed-csc' { 'managed-csc-fallback' }
        'nativeaot' { 'dotnet-nativeaot' }
        'cxx-native' { 'cxx-win32' }
        default { 'none' }
    }

    $result = [pscustomobject]@{
        actionId = 'performance.nativeGovernor.toolchain'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        selectedApproach = $selectedApproach
        workerClassification = $workerClassification
        workerIsTrueNative = $workerClassification -in @('cxx-native','nativeaot')
        cxxWin32Available = [bool]$cxxWin32Available
        dotnetNativeAotAvailable = [bool]$dotnetNativeAotAvailable
        dotnetSdkAvailable = [bool]$dotnetSdkAvailable
        dotnetRuntimeAvailable = @($dotnetCandidates | Where-Object { $_.exists }).Count -gt 0
        selectedDotnetSdkHost = $selectedSdkHost
        dotnetCandidates = @($dotnetCandidates)
        cscFrameworkCompilerAvailable = $null -ne $cscPath
        cscFrameworkCompilerPath = $cscPath
        buildOutputWillUseSdk = $false
        buildOutputReason = if ($dotnetNativeAotAvailable) {
            'SDK host is available, but this pass keeps managed csc output until a better worker is actually built and measured.'
        } elseif ($dotnetSdkAvailable) {
            'SDK host is available, but NativeAOT is not available without the MSVC native toolchain; managed csc remains the validated fallback.'
        } else {
            'No SDK host is available; managed csc remains the fallback when csc.exe exists.'
        }
        commands = [pscustomobject]@{
            dotnet = Get-CommandInfo 'dotnet.exe'
            cl = if ($clCommand) { [pscustomobject]@{ name = $clCommand.Name; source = $clCommand.Source; version = if ($clCommand.Version) { [string]$clCommand.Version } else { $null } } } elseif ($vsCl) { [pscustomobject]@{ name = 'cl.exe'; source = $vsCl.FullName; version = $null } } elseif ($vsX86Cl) { [pscustomobject]@{ name = 'cl.exe'; source = $vsX86Cl.FullName; version = $null } } else { $null }
            clang = $clang
            clangCl = $clangCl
            gcc = $gcc
            gpp = $gpp
            csc = if ($cscPath) { [pscustomobject]@{ name = 'csc.exe'; source = $cscPath; version = $null } } else { $null }
        }
        notes = @(
            'No service installation is required for this worker.',
            'All dotnet.exe candidates from PATH plus the user-local Microsoft dotnet path are evaluated for SDK availability.',
            'C++ Win32 and .NET NativeAOT are not selected unless the required native compiler/linker is available and a better worker is actually built in this pass.',
            'The current validated worker output is managed csc, not C++ native and not NativeAOT.'
        )
    }

    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.nativeGovernor.toolchain'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        capturedAtUtc = Get-RooUtcStamp
        status = 'failed'
        errors = @((New-RooIssue 'NATIVE_GOVERNOR_TOOLCHAIN_CHECK_FAILED' $_.Exception.Message 'error' 'performance.nativeGovernor' $PSCommandPath $true 'Inspect local compiler availability and retry.' $null))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
