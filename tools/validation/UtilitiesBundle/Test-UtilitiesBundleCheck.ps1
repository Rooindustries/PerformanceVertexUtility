param(
    [string]$ArchivePath = $env:ROO_INDUSTRIES_UTILITIES_ARCHIVE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$checkScript = Join-Path $repoRoot 'backend\scripts\Test-UtilitiesBundleCatalog.ps1'
$catalogPath = Join-Path $repoRoot 'backend\catalogs\utilities-bundle-catalog.json'
$manifestPath = Join-Path $repoRoot 'modules\utilities_manifest.json'
$samplePath = Join-Path $repoRoot 'backend\samples\utilities-bundle-inventory.sample.json'
$hostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Join-Path $repoRoot 'vendor\Utilities.zip' }
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    Write-Host "FAIL Utilities.zip not found at $ArchivePath. Pass -ArchivePath or set ROO_INDUSTRIES_UTILITIES_ARCHIVE."
    exit 1
}
$ArchivePath = [System.IO.Path]::GetFullPath($ArchivePath)

$failures = New-Object System.Collections.Generic.List[string]
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('utilities-bundle-check-' + [guid]::NewGuid().ToString('N'))

function Read-Record {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Write-Record {
    param(
        [object]$Record,
        [string]$Name
    )

    $path = Join-Path $workRoot $Name
    Set-Content -LiteralPath $path -Value ($Record | ConvertTo-Json -Depth 20) -Encoding UTF8
    return $path
}

function Get-ReversedFields {
    param([object]$Value)

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $properties = @($Value.PSObject.Properties)
        [Array]::Reverse($properties)
        $reversed = [ordered]@{}
        foreach ($property in $properties) { $reversed[$property.Name] = Get-ReversedFields $property.Value }
        return [pscustomobject]$reversed
    }
    if ($Value -is [System.Collections.IList]) {
        return ,@(foreach ($item in $Value) { ,(Get-ReversedFields $item) })
    }
    return $Value
}

function Get-Entry {
    param(
        [object]$Record,
        [string]$Field,
        [scriptblock]$Where
    )

    $found = @($Record.$Field | Where-Object $Where)
    if ($found.Count -eq 0) { throw "No $Field entry matches $Where" }
    return $found[0]
}

function Invoke-Case {
    param(
        [string]$Name,
        [bool]$ExpectPass,
        [string[]]$Arguments
    )

    $output = @(& $hostPath -NoProfile -ExecutionPolicy Bypass -File $checkScript @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $failLines = @($output | Where-Object { $_ -like 'FAIL *' -and $_ -notlike 'FAIL Utilities bundle catalog validation failed*' })

    if ($ExpectPass) {
        $ok = ($exitCode -eq 0) -and ($failLines.Count -eq 0)
    } else {
        $foreign = @($failLines | Where-Object { $_ -notlike '*live archive*' })
        $ok = ($exitCode -eq 1) -and ($failLines.Count -gt 0) -and ($foreign.Count -eq 0)
    }

    if ($ok) {
        Write-Host "PASS $Name (exit $exitCode)"
        foreach ($line in $failLines) { Write-Host "     $line" }
    } else {
        $failures.Add($Name) | Out-Null
        Write-Host "FAIL $Name (exit $exitCode, expected $(if ($ExpectPass) { 'a pass' } else { 'a live archive failure only' }))"
        foreach ($line in $output) { if ($line -like 'FAIL *') { Write-Host "     $line" } }
    }
}

function Invoke-FaultCase {
    param(
        [string]$Name,
        [string]$Record,
        [scriptblock]$Change
    )

    $copy = Read-Record $(if ($Record -eq 'catalog') { $catalogPath } else { $samplePath })
    & $Change $copy
    $path = Write-Record $copy "$Record-fault.json"
    if ($Record -eq 'catalog') {
        Invoke-Case $Name $false @('-CatalogPath', $path, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $ArchivePath)
    } else {
        Invoke-Case $Name $false @('-CatalogPath', $catalogPath, '-ManifestPath', $manifestPath, '-SamplePath', $path, '-ArchivePath', $ArchivePath)
    }
}

New-Item -ItemType Directory -Path $workRoot | Out-Null
try {
    Invoke-Case 'committed record passes' $true @('-CatalogPath', $catalogPath, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $ArchivePath)
    Invoke-Case 'positional arguments keep their meaning' $true @($catalogPath, $manifestPath, $samplePath, $ArchivePath)

    $reorderedCatalog = Write-Record (Get-ReversedFields (Read-Record $catalogPath)) 'catalog-reordered.json'
    $reorderedSample = Write-Record (Get-ReversedFields (Read-Record $samplePath)) 'sample-reordered.json'
    Invoke-Case 'record with every field order reversed passes' $true @('-CatalogPath', $reorderedCatalog, '-ManifestPath', $manifestPath, '-SamplePath', $reorderedSample, '-ArchivePath', $ArchivePath)

    $absentArchive = Join-Path $workRoot 'absent.zip'
    Invoke-Case 'no bundle skips the live comparison' $true @('-CatalogPath', $catalogPath, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $absentArchive)

    Invoke-FaultCase 'catalog path the archive lacks' 'catalog' {
        param($r)
        (Get-Entry $r 'catalogEntries' { $_.extension -eq '.nip' }).archivePath = 'Utilities\Other\missing-profile.nip'
    }
    Invoke-FaultCase 'stale archive size in the sample' 'sample' {
        param($r)
        $r.sourceArchiveSizeBytes = [uint64]$r.sourceArchiveSizeBytes + 1
    }
    Invoke-FaultCase 'wrong category total in the catalog' 'catalog' {
        param($r)
        $r.summary.categoryCounts.'nvidia-profile' = [int]$r.summary.categoryCounts.'nvidia-profile' + 1
    }
    Invoke-FaultCase 'wrong cataloged entry count in the sample' 'sample' {
        param($r)
        $r.catalogedEntryCount = [int]$r.catalogedEntryCount + 1
    }
    Invoke-FaultCase 'duplicated catalog entry in place of another' 'catalog' {
        param($r)
        $payload = @(for ($i = 0; $i -lt $r.catalogEntries.Count; $i++) { if ($r.catalogEntries[$i].entryKind -ne 'executable-script') { $i } })
        $r.catalogEntries[$payload[1]] = $r.catalogEntries[$payload[0]]
    }
    Invoke-FaultCase 'missing catalog entry' 'catalog' {
        param($r)
        $drop = Get-Entry $r 'catalogEntries' { $_.entryKind -ne 'executable-script' }
        $r.catalogEntries = @($r.catalogEntries | Where-Object { -not [object]::ReferenceEquals($_, $drop) })
        $r.catalogedEntryCount = $r.catalogEntries.Count
    }
    Invoke-FaultCase 'extra catalog entry' 'catalog' {
        param($r)
        $extra = (Get-Entry $r 'catalogEntries' { $_.extension -eq '.inf' }) | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $extra.archivePath = 'Utilities\Drivers\extra.inf'
        $r.catalogEntries = @($r.catalogEntries) + @($extra)
        $r.catalogedEntryCount = $r.catalogEntries.Count
    }
    Invoke-FaultCase 'field removed from a catalog entry' 'catalog' {
        param($r)
        $r.catalogEntries[0].PSObject.Properties.Remove('lengthBytes')
    }
    Invoke-FaultCase 'field removed from a sample entry' 'sample' {
        param($r)
        $r.sampleCatalogEntries[0].PSObject.Properties.Remove('lengthBytes')
    }
    Invoke-FaultCase 'catalog list turned into a single string' 'catalog' {
        param($r)
        $entry = Get-Entry $r 'catalogEntries' { @($_.hardwareGates).Count -eq 1 }
        $entry.hardwareGates = [string]@($entry.hardwareGates)[0]
    }
    Invoke-FaultCase 'sample list turned into a single string' 'sample' {
        param($r)
        $entry = Get-Entry $r 'sampleCatalogEntries' { @($_.hardwareGates).Count -eq 1 }
        $entry.hardwareGates = [string]@($entry.hardwareGates)[0]
    }
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'PASS Utilities bundle check cases completed.'
    exit 0
}
Write-Host "FAIL Utilities bundle check cases failed: $($failures -join '; ')"
exit 1
