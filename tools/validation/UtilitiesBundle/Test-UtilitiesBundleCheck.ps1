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
$ArchivePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    Write-Host "FAIL Utilities.zip not found at $ArchivePath. Pass -ArchivePath or set ROO_INDUSTRIES_UTILITIES_ARCHIVE."
    exit 1
}

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

function ConvertTo-Literal {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Case {
    param(
        [string]$Name,
        [bool]$ExpectPass,
        [string[]]$Arguments,
        [string]$Prefix = '',
        [string]$Expect = '',
        [string]$Refuse = ''
    )

    if ($Prefix) {
        $call = @($Arguments | ForEach-Object { if ($_.StartsWith('-')) { $_ } else { ConvertTo-Literal $_ } }) -join ' '
        $output = @(& $hostPath -NoProfile -ExecutionPolicy Bypass -Command "$Prefix; & $(ConvertTo-Literal $checkScript) $call; exit `$LASTEXITCODE" 2>&1 | ForEach-Object { [string]$_ })
    } else {
        $output = @(& $hostPath -NoProfile -ExecutionPolicy Bypass -File $checkScript @Arguments 2>&1 | ForEach-Object { [string]$_ })
    }
    $exitCode = $LASTEXITCODE
    $failLines = @($output | Where-Object { $_ -like 'FAIL *' -and $_ -notlike 'FAIL Utilities bundle catalog validation failed*' })

    if ($ExpectPass) {
        $ok = ($exitCode -eq 0) -and ($failLines.Count -eq 0)
        if ($Expect) { $ok = $ok -and (@($output | Where-Object { $_ -like "*$Expect*" }).Count -gt 0) }
        if ($Refuse) { $ok = $ok -and (@($output | Where-Object { $_ -like "*$Refuse*" }).Count -eq 0) }
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

function Invoke-RecordCase {
    param(
        [string]$Name,
        [bool]$ExpectPass,
        [string]$Record,
        [string]$Path
    )

    $catalog = if ($Record -eq 'catalog') { $Path } else { $catalogPath }
    $sample = if ($Record -eq 'sample') { $Path } else { $samplePath }
    Invoke-Case $Name $ExpectPass @('-CatalogPath', $catalog, '-ManifestPath', $manifestPath, '-SamplePath', $sample, '-ArchivePath', $ArchivePath)
}

function Invoke-FaultCase {
    param(
        [string]$Name,
        [string]$Record,
        [scriptblock]$Change
    )

    $copy = Read-Record $(if ($Record -eq 'catalog') { $catalogPath } else { $samplePath })
    & $Change $copy
    Invoke-RecordCase $Name $false $Record (Write-Record $copy "$Record-fault.json")
}

function Invoke-TextCase {
    param(
        [string]$Name,
        [bool]$ExpectPass,
        [string]$Record,
        [scriptblock]$Change
    )

    $text = [System.IO.File]::ReadAllText($(if ($Record -eq 'catalog') { $catalogPath } else { $samplePath }))
    $path = Join-Path $workRoot "$Record-text.json"
    [System.IO.File]::WriteAllText($path, [string](& $Change $text), (New-Object System.Text.UTF8Encoding $false))
    Invoke-RecordCase $Name $ExpectPass $Record $path
}

function Edit-First {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replacement
    )

    $regex = New-Object System.Text.RegularExpressions.Regex $Pattern
    if (-not $regex.IsMatch($Text)) { throw "No match for $Pattern" }
    return $regex.Replace($Text, $Replacement, 1)
}

New-Item -ItemType Directory -Path $workRoot | Out-Null
try {
    Invoke-Case 'committed record passes' $true @('-CatalogPath', $catalogPath, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $ArchivePath)
    Invoke-Case 'positional arguments keep their meaning' $true @($catalogPath, $manifestPath, $samplePath, $ArchivePath)

    $reorderedCatalog = Write-Record (Get-ReversedFields (Read-Record $catalogPath)) 'catalog-reordered.json'
    $reorderedSample = Write-Record (Get-ReversedFields (Read-Record $samplePath)) 'sample-reordered.json'
    Invoke-Case 'record with every field order reversed passes' $true @('-CatalogPath', $reorderedCatalog, '-ManifestPath', $manifestPath, '-SamplePath', $reorderedSample, '-ArchivePath', $ArchivePath)

    Invoke-TextCase 'the same number written another way passes' $true 'sample' {
        param($t)
        Edit-First $t '("entryCount"\s*:\s*)770,' '${1}7.70e2,'
    }

    $absentArchive = Join-Path $workRoot 'absent.zip'
    $skipped = 'comparison skipped'
    Invoke-Case 'no bundle skips the live comparison' $true @('-CatalogPath', $catalogPath, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $absentArchive) -Expect $skipped
    $nullRecord = Join-Path $workRoot 'null.json'
    $emptyList = Join-Path $workRoot 'empty-list.json'
    [System.IO.File]::WriteAllText($nullRecord, 'null')
    [System.IO.File]::WriteAllText($emptyList, '[]')
    Invoke-Case 'no bundle with a null catalog reports as before' $true @('-CatalogPath', $nullRecord, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $absentArchive) -Refuse $skipped
    Invoke-Case 'no bundle with an empty list catalog reports as before' $true @('-CatalogPath', $emptyList, '-ManifestPath', $manifestPath, '-SamplePath', $samplePath, '-ArchivePath', $absentArchive) -Refuse $skipped
    Invoke-Case 'no bundle with a null sample reports as before' $true @('-CatalogPath', $catalogPath, '-ManifestPath', $manifestPath, '-SamplePath', $nullRecord, '-ArchivePath', $absentArchive) -Expect $skipped

    Invoke-TextCase 'UTC time written with +00:00 passes' $true 'sample' {
        param($t)
        Edit-First $t '("generatedAtUtc"\s*:\s*"[^"]*)Z"' '${1}+00:00"'
    }
    Invoke-TextCase 'UTC time written with -00:00 passes' $true 'catalog' {
        param($t)
        Edit-First $t '("generatedAtUtc"\s*:\s*"[^"]*)Z"' '${1}-00:00"'
    }

    $processFolder = Join-Path $workRoot 'process'
    $sessionFolder = Join-Path $workRoot 'session'
    New-Item -ItemType Directory -Path $processFolder, $sessionFolder | Out-Null
    Copy-Item -LiteralPath $catalogPath -Destination (Join-Path $processFolder 'catalog.json')
    Copy-Item -LiteralPath $samplePath -Destination (Join-Path $processFolder 'sample.json')
    $staleCatalog = Read-Record $catalogPath
    $staleCatalog.catalogEntries[0].lengthBytes = [uint64]$staleCatalog.catalogEntries[0].lengthBytes + 1
    Set-Content -LiteralPath (Join-Path $sessionFolder 'catalog.json') -Value ($staleCatalog | ConvertTo-Json -Depth 20) -Encoding UTF8
    $staleSample = Read-Record $samplePath
    $staleSample.sourceArchiveSizeBytes = [uint64]$staleSample.sourceArchiveSizeBytes + 1
    Set-Content -LiteralPath (Join-Path $sessionFolder 'sample.json') -Value ($staleSample | ConvertTo-Json -Depth 20) -Encoding UTF8
    $correctFolder = Join-Path $workRoot 'correct'
    New-Item -ItemType Directory -Path $correctFolder | Out-Null
    Copy-Item -LiteralPath $catalogPath -Destination (Join-Path $correctFolder 'catalog.json')
    $splitLocation = "[System.Environment]::CurrentDirectory = $(ConvertTo-Literal $processFolder); Set-Location -LiteralPath $(ConvertTo-Literal $sessionFolder)"
    Invoke-Case 'relative catalog path read from the caller location passes when correct' $true @('-CatalogPath', 'catalog.json', '-ArchivePath', $ArchivePath) -Prefix "[System.Environment]::CurrentDirectory = $(ConvertTo-Literal $processFolder); Set-Location -LiteralPath $(ConvertTo-Literal $correctFolder)" -Expect 'catalogEntries match the live archive'

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

    Invoke-TextCase 'catalog that is null' $false 'catalog' { param($t) 'null' }
    Invoke-TextCase 'sample that is null' $false 'sample' { param($t) 'null' }
    Invoke-TextCase 'sample that is an empty list' $false 'sample' { param($t) '[]' }
    Invoke-TextCase 'catalog wrapped in a list' $false 'catalog' { param($t) '[' + $t + ']' }
    Invoke-TextCase 'sample wrapped in a list' $false 'sample' { param($t) '[' + $t + ']' }
    Invoke-TextCase 'fractional entry count in the sample' $false 'sample' {
        param($t)
        Edit-First $t '("entryCount"\s*:\s*)770,' '${1}770.0000000000001,'
    }
    Invoke-TextCase 'fractional archive size in the sample' $false 'sample' {
        param($t)
        Edit-First $t '("sourceArchiveSizeBytes"\s*:\s*)3734508425,' '${1}3734508425.000001,'
    }
    Invoke-TextCase 'fractional byte length in a catalog entry' $false 'catalog' {
        param($t)
        Edit-First $t '("lengthBytes"\s*:\s*)54864,' '${1}54864.00000000001,'
    }
    Invoke-TextCase 'count written as a string in the sample' $false 'sample' {
        param($t)
        Edit-First $t '("entryCount"\s*:\s*)770,' '${1}"770",'
    }
    Invoke-TextCase 'boolean written as a string in the catalog' $false 'catalog' {
        param($t)
        Edit-First $t '("archiveMetadataOnly"\s*:\s*)true' '${1}"true"'
    }
    Invoke-TextCase 'repeated header field in the sample' $false 'sample' {
        param($t)
        Edit-First $t '("entryCount"\s*:\s*770,)' ('"entryCount":  1,' + [Environment]::NewLine + '    ${1}')
    }
    Invoke-TextCase 'invisible character in a sample header name' $false 'sample' {
        param($t)
        Edit-First $t '"productName"' '"product\u00adName"'
    }
    Invoke-TextCase 'invisible character in a sample summary name' $false 'sample' {
        param($t)
        Edit-First $t '"\.exe"(\s*:)' '".e\u00adxe"${1}'
    }
    Invoke-TextCase 'invisible character in a sample header value' $false 'sample' {
        param($t)
        Edit-First $t 'Optimization Suite' ('Optimi' + [char]0x00AD + 'zation Suite')
    }
    Invoke-TextCase 'invisible character in a catalog entry value' $false 'catalog' {
        param($t)
        Edit-First $t '"AffTool intPolicy"' ('"AffTool int' + [char]0x00AD + 'Policy"')
    }
    Invoke-FaultCase 'catalog entry list inside the sample' 'sample' {
        param($r)
        $r | Add-Member -NotePropertyName 'catalogEntries' -NotePropertyValue @('not an entry')
    }
    Invoke-FaultCase 'catalog without its generation time' 'catalog' {
        param($r)
        $r.PSObject.Properties.Remove('generatedAtUtc')
    }
    Invoke-FaultCase 'sample generation time turned into a list' 'sample' {
        param($r)
        $r.generatedAtUtc = @('bogus')
    }
    Invoke-FaultCase 'sample generation time that is not a time' 'sample' {
        param($r)
        $r.generatedAtUtc = 'yesterday'
    }
    Invoke-FaultCase 'unexpected field in a catalog entry' 'catalog' {
        param($r)
        $r.catalogEntries[0] | Add-Member -NotePropertyName 'note' -NotePropertyValue 'x'
    }
    Invoke-Case 'stale catalog given by a path relative to the caller location' $false @('-CatalogPath', 'catalog.json', '-ArchivePath', $ArchivePath) -Prefix $splitLocation
    Invoke-Case 'stale sample given by a path relative to the caller location' $false @('-SamplePath', 'sample.json', '-ArchivePath', $ArchivePath) -Prefix $splitLocation
    Invoke-Case 'bundle given through a PowerShell drive with a stale catalog' $false @('-CatalogPath', (Join-Path $sessionFolder 'catalog.json'), '-ArchivePath', ('BundleCase:\' + (Split-Path -Leaf $ArchivePath))) -Prefix "New-PSDrive -Name BundleCase -PSProvider FileSystem -Root $(ConvertTo-Literal (Split-Path -Parent $ArchivePath)) | Out-Null"

    Invoke-TextCase 'sample field named Keys' $false 'sample' {
        param($t)
        Edit-First $t '\A(\s*)\{' '${1}{ "Keys": [],'
    }
    Invoke-TextCase 'sample fields named Keys and unexpected' $false 'sample' {
        param($t)
        Edit-First $t '\A(\s*)\{' '${1}{ "Keys": [], "unexpected": true,'
    }
    Invoke-TextCase 'catalog fields named Values and Count' $false 'catalog' {
        param($t)
        Edit-First $t '\A(\s*)\{' '${1}{ "Values": [], "Count": 0,'
    }
    Invoke-TextCase 'catalog entry field named Item' $false 'catalog' {
        param($t)
        Edit-First $t '("catalogEntries"\s*:\s*\[\s*)\{' '${1}{ "Item": null,'
    }
    Invoke-TextCase 'generation time with a non-UTC offset' $false 'sample' {
        param($t)
        Edit-First $t '("generatedAtUtc"\s*:\s*"[^"]*)Z"' '${1}+01:00"'
    }
    Invoke-TextCase 'generation time on a day that does not exist' $false 'catalog' {
        param($t)
        Edit-First $t '("generatedAtUtc"\s*:\s*)"[^"]*"' '${1}"2026-02-30T00:00:00Z"'
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
