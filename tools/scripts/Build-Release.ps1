param(
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE,
    [string]$IsccPath = '',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$releaseTools = Join-Path $repoRoot 'tools\release'
$appProject = Join-Path $repoRoot 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot 'artifacts\release' }
$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot).TrimEnd('\')
$obfuscarVersion = '2.2.50'

function Resolve-DotNetSdk([string]$RequestedPath) {
    $candidates = @($RequestedPath, (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'))
    $command = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $sdks = & $candidate --list-sdks 2>$null
        if ($LASTEXITCODE -eq 0 -and @($sdks | Where-Object { $_ -match '^8\.' }).Count -gt 0) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'No dotnet executable with a .NET 8 SDK was found. Pass -DotNetPath or set ROO_INDUSTRIES_DOTNET_EXE.'
}

function Resolve-Iscc([string]$RequestedPath) {
    $candidates = @($RequestedPath, (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'), (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'Inno Setup 6 was not found. Install it with: winget install JRSoftware.InnoSetup --scope user'
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments, [string]$Step) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE." }
}

function Copy-Tree([string]$Source, [string]$Destination, [string[]]$Include = @('*'), [string[]]$Exclude = @()) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    Get-ChildItem -LiteralPath $Source -File -Recurse | Where-Object {
        $name = $_.Name
        (@($Include | Where-Object { $name -like $_ }).Count -gt 0) -and (@($Exclude | Where-Object { $name -like $_ }).Count -eq 0)
    } | ForEach-Object {
        $target = Join-Path $Destination $_.FullName.Substring($Source.Length).TrimStart('\')
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target
    }
}

function Remove-Tree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $long = if ($Path.StartsWith('\\')) { '\\?\UNC\' + $Path.Substring(2) } else { '\\?\' + $Path }
    & cmd.exe /d /c ('rd /s /q "' + $long + '"')
    if (Test-Path -LiteralPath $Path) { throw "Could not remove $Path." }
}

function Invoke-Obfuscar([string]$Tool, [string]$Directory, [string[]]$Modules, [string]$MapDirectory) {
    $out = Join-Path $work ('obfuscated-' + [IO.Path]::GetFileName($Directory))
    Remove-Tree $out
    $moduleXml = ($Modules | ForEach-Object { '  <Module file="$(InPath)\' + $_ + '"><SkipMethod type="*" rx="^\.ctor$" /></Module>' }) -join "`r`n"
    $config = [IO.File]::ReadAllText((Join-Path $releaseTools 'obfuscar.xml')).Replace('{InPath}', [Security.SecurityElement]::Escape($Directory)).Replace('{OutPath}', [Security.SecurityElement]::Escape($out)).Replace('{Modules}', $moduleXml)
    $configPath = Join-Path $work ('obfuscar-' + [IO.Path]::GetFileName($Directory) + '.xml')
    [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
    Invoke-Checked $Tool @($configPath) ('Obfuscation of ' + $Directory)
    foreach ($module in $Modules) {
        $obfuscated = Join-Path $out $module
        if (-not (Test-Path -LiteralPath $obfuscated)) { throw "Obfuscar did not produce $module." }
        Copy-Item -LiteralPath $obfuscated -Destination (Join-Path $Directory $module) -Force
    }
    [IO.Directory]::CreateDirectory($MapDirectory) | Out-Null
    Copy-Item -LiteralPath (Join-Path $out 'obfuscar-map.xml') -Destination (Join-Path $MapDirectory ([IO.Path]::GetFileName($Directory) + '-map.xml')) -Force
}

$project = [xml](Get-Content -LiteralPath $appProject -Raw)
$version = @($project.Project.PropertyGroup | ForEach-Object { $_.SelectSingleNode('Version') } | Where-Object { $_ })[0].InnerText
if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$') { throw "The app project version '$version' is not a release version." }
$numericVersion = '{0}.{1}.{2}.0' -f $Matches[1], $Matches[2], $Matches[3]

$dotnet = Resolve-DotNetSdk $DotNetPath
$iscc = Resolve-Iscc $IsccPath
Write-Host "Version $version using $dotnet and $iscc"
Write-Host ('Bug report webhook: ' + $(if ([string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_BUG_WEBHOOK)) { 'not set, testers save reports to a file' } else { 'embedded from ROO_INDUSTRIES_BUG_WEBHOOK' }))

$work = Join-Path $OutputRoot ('work-' + $version)
$stage = Join-Path $work 'stage'
$maps = Join-Path $OutputRoot ($version + '-obfuscation-maps')
Remove-Tree $work
Remove-Tree $maps
[IO.Directory]::CreateDirectory($stage) | Out-Null
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_ROOT = Split-Path $dotnet -Parent

$tools = Join-Path $work 'tools'
Invoke-Checked $dotnet @('tool', 'install', 'Obfuscar.GlobalTool', '--version', $obfuscarVersion, '--tool-path', $tools) 'Obfuscar install'
$obfuscar = Join-Path $tools 'obfuscar.console.exe'

$hostOut = Join-Path $stage 'backend\bin\optimizer'
$sessionOut = Join-Path $hostOut 'session'
$appOut = Join-Path $stage 'app'
$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:UseSharedCompilation=false', '-p:DebugType=none', '-p:ContinuousIntegrationBuild=true', '-p:GenerateDocumentationFile=false')
Invoke-Checked $dotnet (@('publish', (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj'), '-o', $hostOut) + $common) 'Helper publish'
Invoke-Checked $dotnet (@('publish', (Join-Path $repoRoot 'backend\native\Optimizer.SessionHost\Optimizer.SessionHost.csproj'), '-o', $sessionOut) + $common) 'Session helper publish'
Invoke-Checked $dotnet (@('publish', $appProject, '-o', $appOut, '-p:Platform=x64', '-p:WindowsAppSDKSelfContained=true', '-p:WindowsPackageType=None', ('-p:SelfContainedIntermediateOutputPath=' + (Join-Path $work 'wasdk') + '/'),
    ('-p:ApplicationManifest=' + (Join-Path $releaseTools 'app.release.manifest'))) + $common) 'App publish'

$productAssemblies = @((Join-Path $hostOut 'Optimizer.Core.dll'), (Join-Path $hostOut 'Optimizer.Host.dll'), (Join-Path $sessionOut 'RooIndustries.SessionHost.dll'), (Join-Path $appOut 'RooIndustries.OptimizationSuite.App.dll'))
Invoke-Checked $dotnet (@('run', '--project', (Join-Path $repoRoot 'tools\validation\DynamicBinding\DynamicBinding.csproj'), '-c', 'Release', '--') + $productAssemblies) 'Dynamic binding check'

Invoke-Obfuscar $obfuscar $hostOut @('Optimizer.Core.dll', 'Optimizer.Host.dll') $maps
Invoke-Obfuscar $obfuscar $sessionOut @('Optimizer.Core.dll', 'RooIndustries.SessionHost.dll') $maps
Invoke-Obfuscar $obfuscar $appOut @('Optimizer.Core.dll', 'RooIndustries.OptimizationSuite.App.dll') $maps

$backend = Join-Path $repoRoot 'backend'
$buildOnlyScripts = @('Test-*.ps1', 'Measure-Optimizer*.ps1', 'Measure-ProcessControlFootprint.ps1', 'Validation.Common.ps1', 'Get-RooIndustriesValidationTempArtifacts.ps1', 'Build-OptimizerHost.ps1')
Copy-Tree (Join-Path $backend 'scripts') (Join-Path $stage 'backend\scripts') @('*.ps1') $buildOnlyScripts
Copy-Tree (Join-Path $backend 'catalogs') (Join-Path $stage 'backend\catalogs') @('windows-tweaks.json', 'firmware-write-tests.json', 'stutter-optimization-ranking.json', 'nvidia-profile-inspector-nip-catalog.json', 'upstream-settings-inventory.json')
Copy-Tree (Join-Path $backend 'capabilities') (Join-Path $stage 'backend\capabilities') @('*.json')
Copy-Tree (Join-Path $backend 'profiles') (Join-Path $stage 'backend\profiles') @('*.json')
$samples = @(
    'app-classification.sample.json', 'capability-registry.sample.json', 'cleanup-deletion-manifest.sample.json',
    'dashboard-backend-status.sample.json', 'driver-hardware-summary.sample.json', 'driver-recommendation-catalog.sample.json',
    'game-session-profile-preview.sample.json', 'game-tune-session-restore-preview.sample.json', 'game-tune-session-status.sample.json', 'installed-app-inventory.sample.json',
    'leftover-scan-preview.sample.json', 'nvidia-nip-preview.sample.json', 'nvidia-profile-catalog.sample.json',
    'official-uninstall-preview.sample.json', 'process-classification.sample.json', 'process-governor-session-status.sample.json',
    'process-inventory.sample.json', 'process-profile-preview.sample.json', 'product-backend-status.sample.json', 'report-summary.sample.json',
    'stutter-optimization-preview.sample.json', 'telemetry-snapshot.sample.json', 'uninstall-cleanup-execution-plan.sample.json',
    'uninstall-queue.sample.json'
)
Copy-Tree (Join-Path $backend 'samples') (Join-Path $stage 'backend\samples') $samples
Copy-Tree (Join-Path $backend 'uninstall') (Join-Path $stage 'backend\uninstall') @('*.json')
foreach ($native in @('CpuSets', 'ProcessGovernor', 'ProcessOutput', 'StandbyMemoryHelper')) {
    Copy-Tree (Join-Path $backend "native\$native") (Join-Path $stage "backend\native\$native") @('*.cs')
}
Copy-Tree (Join-Path $repoRoot 'modules') (Join-Path $stage 'modules') @('*.json')
Copy-Tree (Join-Path $repoRoot 'assets\brand\roo-industries') (Join-Path $stage 'assets\brand\roo-industries') @('favicon-96x96.png', 'web-app-manifest-192x192.png', 'embed_logo.png', 'favicon.ico')
[IO.File]::WriteAllText((Join-Path $stage 'README-BETA.txt'), [IO.File]::ReadAllText((Join-Path $releaseTools 'README-BETA.txt')).Replace('{Version}', $version), [Text.UTF8Encoding]::new($false))

Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.pdb' | Remove-Item -Force
foreach ($required in @('app\RooIndustries.OptimizationSuite.App.exe', 'backend\bin\optimizer\Optimizer.Host.exe', 'backend\bin\optimizer\hostpolicy.dll', 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe', 'backend\samples', 'backend\catalogs\windows-tweaks.json', 'app\Microsoft.WindowsAppRuntime.dll', 'app\RooIndustries.OptimizationSuite.App.pri')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "The release layout is missing $required." }
}

$smokeRequest = Join-Path $work 'smoke-request.json'
[IO.File]::WriteAllText($smokeRequest, (@{ schemaVersion = 1; repoRoot = $stage } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$smoke = (& (Join-Path $hostOut 'Optimizer.Host.exe') 'tweak-catalog' $smokeRequest) -join "`n"
if ($LASTEXITCODE -ne 0 -or $smoke -notmatch '"status"\s*:\s*"completed"' -or $smoke -notmatch '"settings"\s*:\s*\[\s*\{') { throw 'The obfuscated helper could not read the Windows tweak catalog.' }
Write-Host ('Smoke test: the obfuscated helper returned the Windows tweak catalog (' + $smoke.Length + ' characters).')

[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$setupName = "RooIndustries-OptimizationSuite-$version-setup"
Invoke-Checked $iscc @('/Q', "/DAppVersion=$version", "/DAppNumericVersion=$numericVersion", "/DSourceDir=$stage", "/DOutputDir=$OutputRoot", "/DOutputName=$setupName", (Join-Path $releaseTools 'RooIndustries.OptimizationSuite.iss')) 'Installer build'
$setup = Join-Path $OutputRoot ($setupName + '.exe')
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($setup + '.sha256', $hash + '  ' + [IO.Path]::GetFileName($setup) + "`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ version = $version; installer = $setup; bytes = (Get-Item -LiteralPath $setup).Length; sha256 = $hash; stage = $stage; obfuscationMaps = $maps } | ConvertTo-Json
