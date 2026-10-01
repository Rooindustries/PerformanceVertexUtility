$script:ForbiddenReleaseScripts = @('Test-*', 'Measure-Optimizer*', 'Measure-ProcessControlFootprint*', 'Build-NativeProcessGovernor*', 'Start-NativeProcessGovernorSession*', 'Get-NativeProcessGovernorToolchain*', 'Build-OptimizerHost*', 'Validation.Common*', 'Get-RooIndustriesValidationTempArtifacts*', 'Scenario.*')

function Get-ReleaseScriptNames([string]$RepoRoot) {
    $path = Join-Path $RepoRoot 'tools\release\shipped-scripts.txt'
    $names = @(Get-Content -LiteralPath $path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($name in $names) {
        if ($name -notmatch '^[A-Za-z0-9._-]+\.(ps1|cmd)$') { throw "shipped-scripts.txt lists '$name', which is not a plain script file name." }
        if (Test-ForbiddenReleaseScript $name) { throw "shipped-scripts.txt lists $name, a scenario, test or developer script." }
    }
    $duplicate = @($names | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($duplicate.Count -gt 0) { throw ('shipped-scripts.txt lists ' + ($duplicate -join ', ') + ' more than once.') }
    return $names
}

function Test-ForbiddenReleaseScript([string]$RelativePath) {
    $name = [IO.Path]::GetFileName($RelativePath)
    if ($RelativePath -match '(^|[\\/])GovernorScenarios([\\/]|$)') { return $true }
    foreach ($pattern in $script:ForbiddenReleaseScripts) { if ($name -like $pattern) { return $true } }
    return $false
}

function Copy-ReleaseScripts([string]$RepoRoot, [string]$Stage) {
    $source = Join-Path $RepoRoot 'backend\scripts'
    $target = Join-Path $Stage 'backend\scripts'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    foreach ($name in (Get-ReleaseScriptNames $RepoRoot)) {
        $file = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "shipped-scripts.txt lists $name, which is not in backend\scripts." }
        Copy-Item -LiteralPath $file -Destination (Join-Path $target $name)
    }
}

function Get-ReleaseScriptCalls([string]$RepoRoot, [string]$Stage) {
    $known = @{}
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'backend\scripts') -File)) { if ($file.Extension -in '.ps1', '.cmd') { $known[$file.Name.ToLowerInvariant()] = $file.Name } }
    $quote = '["' + "'" + [char]96 + ']'
    $literal = [regex]::new($quote + '(?:[^"' + "'" + [char]96 + '\s]*[\\/])?([A-Za-z0-9_.-]+\.(?:ps1|cmd))' + $quote, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $sources = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(
        @('backend\native\Optimizer.Core', '*.cs'), @('backend\native\Optimizer.Host', '*.cs'), @('backend\native\Optimizer.SessionHost', '*.cs'),
        @('docs\internal\frontend', '*.cs'), @('docs\internal\frontend', '*.xaml'), @('backend\capabilities', '*.json'), @('backend\profiles', '*.json'),
        @('backend\catalogs', '*.json'), @('modules', '*.json'), @('tools\release', '*.iss'))) {
        $folder = Join-Path $RepoRoot $entry[0]
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter $entry[1] -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/](obj|bin)[\\/]' })) { $sources.Add($file.FullName) }
    }
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $Stage 'backend\scripts') -File -Recurse)) { if ($file.Extension -in '.ps1', '.cmd') { $sources.Add($file.FullName) } }
    $calls = @{}
    foreach ($path in $sources) {
        foreach ($match in $literal.Matches([IO.File]::ReadAllText($path))) {
            $key = $match.Groups[1].Value.ToLowerInvariant()
            if ($known.ContainsKey($key) -and -not (Test-ForbiddenReleaseScript $known[$key]) -and -not $calls.ContainsKey($known[$key])) { $calls[$known[$key]] = $path.Substring($RepoRoot.TrimEnd('\').Length).TrimStart('\') }
        }
    }
    return $calls
}

function Assert-ReleaseScripts([string]$RepoRoot, [string]$Stage) {
    $scripts = Join-Path $Stage 'backend\scripts'
    $staged = @(Get-ChildItem -LiteralPath $scripts -File -Recurse | ForEach-Object { $_.FullName.Substring($scripts.Length).TrimStart('\') })
    foreach ($name in $staged) { if (Test-ForbiddenReleaseScript $name) { throw "The release stage contains $name, a scenario, test or developer script." } }
    $listed = @(Get-ReleaseScriptNames $RepoRoot)
    foreach ($name in $staged) { if ($listed -notcontains $name) { throw "The release stage contains $name, which shipped-scripts.txt does not list." } }
    foreach ($name in $listed) { if ($staged -notcontains $name) { throw "The release stage is missing $name, which shipped-scripts.txt lists." } }
    $calls = Get-ReleaseScriptCalls $RepoRoot $Stage
    foreach ($name in ($calls.Keys | Sort-Object)) { if ($staged -notcontains $name) { throw "The product calls $name (see $($calls[$name])), but the release stage does not contain it." } }
}

function Compare-ReleaseVersion([string]$Left, [string]$Right) {
    $pattern = '^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$'
    if ($Left -notmatch $pattern) { throw "'$Left' is not a release version." }
    $a = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]); $suffixA = $Matches[4]
    if ($Right -notmatch $pattern) { throw "'$Right' is not a release version." }
    $b = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]); $suffixB = $Matches[4]
    for ($index = 0; $index -lt 3; $index++) { if ($a[$index] -ne $b[$index]) { return [Math]::Sign($a[$index] - $b[$index]) } }
    if ($suffixA -eq $suffixB) { return 0 }
    if (-not $suffixA) { return 1 }
    if (-not $suffixB) { return -1 }
    return [Math]::Sign([string]::CompareOrdinal($suffixA, $suffixB))
}

function Assert-ReleaseVersion([string]$RepoRoot, [string]$Version) {
    $path = Join-Path $RepoRoot 'tools\release\released-versions.txt'
    foreach ($released in @(Get-Content -LiteralPath $path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })) {
        if ((Compare-ReleaseVersion $Version $released) -le 0) { throw "Version $Version is not newer than the released version $released. Raise Version in the app project." }
    }
}
