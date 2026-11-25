function Resolve-RooIndustriesUtilitiesRoot {
    param([string]$Path)

    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:ROO_INDUSTRIES_UTILITIES_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Utilities')
    }

    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($candidate))
}

function Resolve-RooIndustriesNvidiaProfileFile {
    param(
        [string]$Path,
        [object]$Profile = $null
    )

    $name = [System.IO.Path]::GetFileName($Path)
    if ($null -eq $Profile) {
        $catalogPath = Join-Path $PSScriptRoot '..\catalogs\nvidia-profile-inspector-nip-catalog.json'
        $profiles = @((Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json).profiles)
        $Profile = @($profiles | Where-Object { [System.IO.Path]::GetFileName([string]$_.sourceFile) -eq $name }) |
            Select-Object -First 1
        if ($null -eq $Profile) { return $Path }
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $files = @(Get-ChildItem -LiteralPath $directory -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq [long]$Profile.sourceSizeBytes })
    foreach ($file in @($files | Sort-Object { $_.Name -ne $name }, Name)) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
        if ($null -ne $hash -and $hash.Hash -eq [string]$Profile.sourceSha256) { return $file.FullName }
    }
    return $null
}
