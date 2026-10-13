function ConvertTo-ReleaseExtendedPath([string]$Path) {
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
    $plain = $Path.Replace('/', '\')
    if (($plain -notmatch '^[A-Za-z]:\\' -and $plain -notmatch '^\\\\[^\\]+\\[^\\]+') -or @($plain.Split('\') | Where-Object { $_ -in '.', '..' }).Count) { $plain = [IO.Path]::GetFullPath($plain) }
    if ($plain.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $plain.Substring(2) }
    return '\\?\' + $plain
}

function Get-ReleaseXamlIntermediatePath([string]$RepoRoot, [string]$ProjectRoot = $RepoRoot) {
    $relative = 'docs\internal\frontend\RooIndustries.OptimizationSuite.App'
    $project = [xml][IO.File]::ReadAllText((ConvertTo-ReleaseExtendedPath (Join-Path $ProjectRoot ($relative + '\RooIndustries.OptimizationSuite.App.csproj'))))
    $framework = $project.SelectSingleNode('//TargetFramework').InnerText
    $assembly = $project.SelectSingleNode('//AssemblyName').InnerText
    return Join-Path $RepoRoot ($relative + '\obj\x64\Release\' + $framework + '\win-x64\intermediatexaml\' + $assembly + '.dll')
}

function Assert-ReleasePathBound([string]$RepoRoot, [string]$ProjectRoot = $RepoRoot, [string[]]$OutputRoots = @()) {
    if ($RepoRoot) {
        $path = Get-ReleaseXamlIntermediatePath $RepoRoot $ProjectRoot
        if ($path.Length -ge 260) { throw ('Release XAML path reaches the 260-character limit: ' + $path + '. Use a shorter source root.') }
    }
    foreach ($root in $OutputRoots) {
        $long = ConvertTo-ReleaseExtendedPath $root
        if (-not [IO.Directory]::Exists($long)) { continue }
        $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($long)
        while ($pending.Count) {
            $path = $pending.Pop()
            $plain = if ($path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { '\\' + $path.Substring(8) } else { $path.Substring(4) }
            if ($plain.Length -ge 260) { throw ('Release output path reaches the 260-character limit: ' + $plain + '. Use a shorter source or output root.') }
            $attributes = [IO.File]::GetAttributes($path)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Release path is a reparse point: ' + $plain) }
            if ($attributes -band [IO.FileAttributes]::Directory) { foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($path)) { $pending.Push($entry) } }
        }
    }
}

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

function Copy-ReleaseData([string]$RepoRoot, [string]$Stage) {
    $samples = @(
        'app-classification.sample.json', 'cleanup-deletion-manifest.sample.json',
        'dashboard-backend-status.sample.json', 'driver-hardware-summary.sample.json', 'driver-recommendation-catalog.sample.json',
        'game-session-profile-preview.sample.json', 'game-tune-session-restore-preview.sample.json', 'game-tune-session-status.sample.json', 'installed-app-inventory.sample.json',
        'leftover-scan-preview.sample.json', 'nvidia-nip-preview.sample.json', 'nvidia-profile-catalog.sample.json',
        'official-uninstall-preview.sample.json', 'process-classification.sample.json', 'process-governor-session-status.sample.json',
        'process-inventory.sample.json', 'process-profile-preview.sample.json', 'product-backend-status.sample.json', 'report-summary.sample.json',
        'stutter-optimization-preview.sample.json', 'telemetry-snapshot.sample.json', 'uninstall-cleanup-execution-plan.sample.json',
        'uninstall-queue.sample.json'
    )
    foreach ($entry in @(
        @('backend\catalogs', @('windows-tweaks.json', 'firmware-write-tests.json', 'stutter-optimization-ranking.json', 'nvidia-profile-inspector-nip-catalog.json', 'upstream-settings-inventory.json')),
        @('backend\profiles', @('*.json')), @('backend\samples', $samples), @('backend\uninstall', @('*.json')), @('modules', @('*.json')))) {
        $source = Join-Path $RepoRoot $entry[0]
        $destination = Join-Path $Stage $entry[0]
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        foreach ($pattern in $entry[1]) {
            foreach ($file in (Get-ChildItem -LiteralPath $source -Filter $pattern -File)) { Copy-Item -LiteralPath $file.FullName -Destination $destination }
        }
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
        @('docs\internal\frontend', '*.cs'), @('docs\internal\frontend', '*.xaml'), @('tools\release', '*.iss'))) {
        $folder = Join-Path $RepoRoot $entry[0]
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter $entry[1] -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/](obj|bin)[\\/]' })) { $sources.Add($file.FullName) }
    }
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $Stage 'backend\scripts') -File -Recurse)) { if ($file.Extension -in '.ps1', '.cmd') { $sources.Add($file.FullName) } }
    foreach ($file in (Get-ChildItem -LiteralPath $Stage -Filter '*.json' -File -Recurse)) { $sources.Add($file.FullName) }
    $calls = @{}
    foreach ($path in $sources) {
        foreach ($match in $literal.Matches([IO.File]::ReadAllText($path))) {
            $key = $match.Groups[1].Value.ToLowerInvariant()
            if ($known.ContainsKey($key) -and -not (Test-ForbiddenReleaseScript $known[$key]) -and -not $calls.ContainsKey($known[$key])) { $calls[$known[$key]] = $path }
        }
    }
    return $calls
}

function Assert-ReleaseScripts([string]$RepoRoot, [string]$Stage, [switch]$TestHooks) {
    if(-not $TestHooks -and (Test-Path -LiteralPath (Join-Path $Stage 'backend\test-hooks.enabled'))){throw 'A production release stage contains backend\test-hooks.enabled.'}
    $scripts = Join-Path $Stage 'backend\scripts'
    $staged = @(Get-ChildItem -LiteralPath $scripts -File -Recurse | ForEach-Object { $_.FullName.Substring($scripts.Length).TrimStart('\', '/') })
    foreach ($name in $staged) { if (Test-ForbiddenReleaseScript $name) { throw "The release stage contains $name, a scenario, test or developer script." } }
    $listed = @(Get-ReleaseScriptNames $RepoRoot)
    foreach ($name in $staged) { if ($listed -notcontains $name) { throw "The release stage contains $name, which shipped-scripts.txt does not list." } }
    foreach ($name in $listed) { if ($staged -notcontains $name) { throw "The release stage is missing $name, which shipped-scripts.txt lists." } }
    $calls = Get-ReleaseScriptCalls $RepoRoot $Stage
    foreach ($name in ($calls.Keys | Sort-Object)) { if ($staged -notcontains $name) { throw "The product calls $name (see $($calls[$name])), but the release stage does not contain it." } }
}

function Compare-ReleaseVersion([string]$Left, [string]$Right) {
    $pattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    if ($Left -notmatch $pattern) { throw "'$Left' is not a release version." }
    $a = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]); $suffixA = $Matches[4]
    if ($Right -notmatch $pattern) { throw "'$Right' is not a release version." }
    $b = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]); $suffixB = $Matches[4]
    foreach ($suffix in @($suffixA, $suffixB)) {
        if ($suffix -and @($suffix.Substring(1).Split('.') | Where-Object { $_ -match '^0[0-9]+$' }).Count -gt 0) { throw "'$suffix' is not a release version suffix." }
    }
    for ($index = 0; $index -lt 3; $index++) { if ($a[$index] -ne $b[$index]) { return $a[$index].CompareTo($b[$index]) } }
    if ($suffixA -ceq $suffixB) { return 0 }
    if (-not $suffixA) { return 1 }
    if (-not $suffixB) { return -1 }
    $partsA = $suffixA.Substring(1).Split('.'); $partsB = $suffixB.Substring(1).Split('.')
    for ($index = 0; $index -lt [Math]::Min($partsA.Count, $partsB.Count); $index++) {
        $leftPart = $partsA[$index]; $rightPart = $partsB[$index]
        if ($leftPart -ceq $rightPart) { continue }
        $numericA = $leftPart -match '^[0-9]+$'; $numericB = $rightPart -match '^[0-9]+$'
        if ($numericA -and -not $numericB) { return -1 }
        if ($numericB -and -not $numericA) { return 1 }
        if ($numericA -and $leftPart.Length -ne $rightPart.Length) { return $leftPart.Length.CompareTo($rightPart.Length) }
        return [Math]::Sign([string]::CompareOrdinal($leftPart, $rightPart))
    }
    return $partsA.Count.CompareTo($partsB.Count)
}

function Assert-ReleaseVersion([string]$RepoRoot, [string]$Version) {
    $path = Join-Path $RepoRoot 'tools\release\released-versions.txt'
    foreach ($released in @(Get-Content -LiteralPath $path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })) {
        if ((Compare-ReleaseVersion $Version $released) -le 0) { throw "Version $Version is not newer than the released version $released. Raise Version in the app project." }
    }
}
