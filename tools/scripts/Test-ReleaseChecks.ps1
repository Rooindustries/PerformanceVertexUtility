$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'Release.Checks.ps1')
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; Write-Output ('PASS ' + $Message) }
function Refuses([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { return ([string]$_.Exception.Message -match $Pattern) }
    return $false
}
function Copy-Sources([string]$Target) {
    foreach ($entry in @(
        @('backend\native\Optimizer.Core', @('*.cs')), @('backend\native\Optimizer.Host', @('*.cs')), @('backend\native\Optimizer.SessionHost', @('*.cs')),
        @('docs\internal\frontend', @('*.cs', '*.xaml')), @('backend\capabilities', @('*.json')), @('backend\profiles', @('*.json')),
        @('backend\catalogs', @('*.json')), @('backend\samples', @('*.json')), @('backend\uninstall', @('*.json')), @('modules', @('*.json')), @('tools\release', @('*.iss', '*.txt')), @('backend\scripts', @('*.ps1', '*.cmd')))) {
        $source = Join-Path $repoRoot $entry[0]
        foreach ($file in (Get-ChildItem -LiteralPath $source -Include $entry[1] -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/](obj|bin)[\\/]' })) {
            $destination = Join-Path $Target $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
    }
}
function New-Stage([string]$Root, [string]$Name) {
    $stage = Join-Path $work $Name
    Copy-ReleaseScripts $Root $stage
    Copy-ReleaseData $Root $stage
    return $stage
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-release-checks-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $stage = New-Stage $repoRoot 'real'
    Assert-ReleaseScripts $repoRoot $stage
    $listed = @(Get-ReleaseScriptNames $repoRoot)
    $staged = @(Get-ChildItem -LiteralPath (Join-Path $stage 'backend\scripts') -File -Recurse | ForEach-Object { $_.Name })
    Assert ($staged.Count -eq $listed.Count -and $staged.Count -gt 50) ('The release stage holds exactly the ' + $staged.Count + ' listed scripts')
    Assert (@($staged | Where-Object { Test-ForbiddenReleaseScript $_ }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $stage 'backend\scripts\GovernorScenarios'))) 'The release stage holds no scenario, test or developer script'
    foreach ($planted in @('Test-Planted.ps1', 'GovernorScenarios\Claims.ps1', 'Measure-OptimizerCpu.ps1', 'Measure-ProcessControlFootprint.ps1', 'Build-OptimizerHost.ps1', 'Build-NativeProcessGovernor.ps1', 'Start-NativeProcessGovernorSession.ps1', 'Get-NativeProcessGovernorToolchain.ps1', 'Validation.Common.ps1', 'Get-RooIndustriesValidationTempArtifacts.ps1')) {
        $path = Join-Path $stage ('backend\scripts\' + $planted)
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText($path, '# planted')
        try { Assert (Refuses { Assert-ReleaseScripts $repoRoot $stage } 'scenario, test or developer script') ('The build refuses a staged ' + $planted) }
        finally { Remove-Item -LiteralPath $path -Force; if ($planted -like 'GovernorScenarios*') { Remove-Item -LiteralPath (Split-Path $path -Parent) -Force } }
    }
    $unlisted = Join-Path $stage 'backend\scripts\Get-ProcessPolicyAuditHistory.ps1'
    [IO.File]::WriteAllText($unlisted, '# unlisted')
    try { Assert (Refuses { Assert-ReleaseScripts $repoRoot $stage } 'does not list') 'The build refuses a staged script that the release list does not name' } finally { Remove-Item -LiteralPath $unlisted -Force }
    $gone = Join-Path $stage 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'
    $kept = [IO.File]::ReadAllBytes($gone)
    Remove-Item -LiteralPath $gone
    try { Assert (Refuses { Assert-ReleaseScripts $repoRoot $stage } 'missing Invoke-ProcessPolicyWorker.ps1') 'The build refuses a stage that lost a listed script' } finally { [IO.File]::WriteAllBytes($gone, $kept) }
    $copy = Join-Path $work 'repo'
    Copy-Sources $copy
    $list = Join-Path $copy 'tools\release\shipped-scripts.txt'
    $all = [IO.File]::ReadAllText($list)
    foreach ($called in @(@('Invoke-ProcessPolicyWorker.ps1', 'application code'), @('OperationState.Common.ps1', 'a shipped script'), @('Start-RooIndustriesHelper.cmd', 'a shipped script'), @('Get-AppClassification.ps1', 'application code'))) {
        $name = $called[0]
        [IO.File]::WriteAllText($list, (($all -split "`r?`n" | Where-Object { $_ -and $_ -ne $name }) -join "`n") + "`n")
        $short = New-Stage $copy ('short-' + $name)
        Assert (Refuses { Assert-ReleaseScripts $copy $short } ('product calls ' + [regex]::Escape($name))) ('The build refuses a stage without ' + $name + ', which ' + $called[1] + ' calls')
    }
    [IO.File]::WriteAllText($list, $all)
    $reference = Join-Path $copy 'backend\native\Optimizer.Core\Reference.cs'
    [IO.File]::WriteAllText($reference, 'class Reference { const string Script = "Get-ProcessPolicyAuditHistory.ps1"; }')
    $referenced = New-Stage $copy 'referenced'
    Assert (Refuses { Assert-ReleaseScripts $copy $referenced } 'product calls Get-ProcessPolicyAuditHistory.ps1') 'The build refuses a script the application names that the release list leaves out'
    [IO.File]::WriteAllText($reference, 'class Reference { const string Message = "Run Build-OptimizerHost.ps1 first, then try again."; const string Test = "backend/scripts/Test-Anything.ps1"; }')
    $prose = New-Stage $copy 'prose'
    Assert-ReleaseScripts $copy $prose
    Assert $true 'A sentence or a test reference that mentions a developer script does not count as a call'
    $catalog = Join-Path $prose 'backend\catalogs\release-check.json'
    [IO.File]::WriteAllText($catalog, '{"script":"backend/scripts/Get-ProcessPolicyAuditHistory.ps1"}')
    Assert (Refuses { Assert-ReleaseScripts $copy $prose } 'product calls Get-ProcessPolicyAuditHistory.ps1') 'The build checks a script reference in a staged catalog'
    Remove-Item -LiteralPath $catalog
    [IO.File]::WriteAllText((Join-Path $copy 'backend\catalogs\source-only.json'), '{"script":"backend/scripts/Get-ProcessPolicyAuditHistory.ps1"}')
    Assert-ReleaseScripts $copy $prose
    Assert $true 'A catalog that is absent from the release cannot require its development scripts'
    [IO.File]::WriteAllText($list, $all + "Not-There.ps1`n")
    Assert (Refuses { New-Stage $copy 'absent' } 'not in backend.scripts') 'The build refuses a list entry that is not a script in the repository'
    [IO.File]::WriteAllText($list, $all + "Test-Planted.ps1`n")
    Assert (Refuses { Get-ReleaseScriptNames $copy } 'scenario, test or developer script') 'The release list itself cannot name a test script'
    [IO.File]::WriteAllText($list, $all)
    foreach ($case in @(@('0.10.0-beta', '0.9.0-beta', 1), @('0.9.0-beta', '0.10.0-beta', -1), @('0.10.0-beta', '0.10.0-beta', 0), @('0.10.0', '0.10.0-beta', 1), @('1.0.0-beta', '0.99.9', 1), @('0.9.1-beta', '0.9.0-beta', 1))) {
        Assert ((Compare-ReleaseVersion $case[0] $case[1]) -eq $case[2]) ('Version ' + $case[0] + ' compares as ' + $case[2] + ' against ' + $case[1])
    }
    Assert (('0.10.0-beta' -lt '0.9.0-beta') -and (Compare-ReleaseVersion '0.10.0-beta' '0.9.0-beta') -gt 0) 'Release versions compare by number, not as text where 0.10.0 would sort before 0.9.0'
    foreach ($case in @(@('0.10.0-beta.10', '0.10.0-beta.9', 1), @('0.10.0-beta.9', '0.10.0-beta.10', -1), @('0.10.0-9', '0.10.0-beta', -1), @('0.10.0-beta.1.10', '0.10.0-beta.1.9', 1), @('0.10.0-beta.a', '0.10.0-beta.A', 1), @('0.10.0-beta.1', '0.10.0-beta.1.a', -1), @('0.10.0-beta.99999999999999999999', '0.10.0-beta.9999999999999999999', 1))) {
        Assert ((Compare-ReleaseVersion $case[0] $case[1]) -eq $case[2]) ('Prerelease ' + $case[0] + ' compares as ' + $case[2] + ' against ' + $case[1])
    }
    foreach ($invalid in @('0.10.0-beta..1', '0.10.0-beta.01', '0.10.0-beta.')) {
        Assert (Refuses { Compare-ReleaseVersion $invalid '0.10.0-beta' } 'not a release version') ('Invalid prerelease ' + $invalid + ' is refused')
    }
    [IO.File]::WriteAllText((Join-Path $copy 'tools\release\released-versions.txt'), "0.10.0-beta.9`n")
    Assert-ReleaseVersion $copy '0.10.0-beta.10'
    Assert (Refuses { Assert-ReleaseVersion $copy '0.10.0-beta.8' } 'not newer') 'The release gate accepts beta.10 after beta.9 and refuses beta.8'
    $project = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj') -Raw)
    $version = @($project.Project.PropertyGroup | ForEach-Object { $_.SelectSingleNode('Version') } | Where-Object { $_ })[0].InnerText
    Assert-ReleaseVersion $repoRoot $version
    Assert $true ('The app project version ' + $version + ' is newer than every released version')
    Assert (Refuses { Assert-ReleaseVersion $repoRoot '0.9.0-beta' } 'not newer than the released version 0.9.0-beta') 'The build refuses a version equal to the released one'
    Assert (Refuses { Assert-ReleaseVersion $repoRoot '0.8.5-beta' } 'not newer') 'The build refuses a version older than the released one'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
Assert (-not (Test-Path -LiteralPath $work)) 'The release checks remove their temporary folders'
