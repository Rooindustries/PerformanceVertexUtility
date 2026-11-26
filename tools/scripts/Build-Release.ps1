param(
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE,
    [string]$IsccPath = '',
    [string]$OutputRoot = '',
    [AllowEmptyString()][string]$UpdateFeedUrl,
    [switch]$TestHooks,
    [string]$SignToolPath = $env:ROO_INDUSTRIES_SIGNTOOL,
    [string[]]$SignArguments = @(),
    [string]$SignSubject = $env:ROO_INDUSTRIES_SIGN_SUBJECT,
    [switch]$AllowUntrustedSignature
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Release.Checks.ps1')
if (-not $PSBoundParameters.ContainsKey('SignArguments') -and $env:ROO_INDUSTRIES_SIGN_ARGS_JSON) { $SignArguments = [string[]](ConvertFrom-Json -InputObject $env:ROO_INDUSTRIES_SIGN_ARGS_JSON) }
if ($env:ROO_INDUSTRIES_SIGN_ALLOW_UNTRUSTED -eq '1') { $AllowUntrustedSignature = $true }
$signing = $SignArguments.Count -gt 0
if ($signing) {
    if ([string]::IsNullOrWhiteSpace($SignSubject)) { throw 'SignSubject is required when signing a release.' }
    if (@($SignArguments | Where-Object { $_ -match '^[/-]p(?:$|[\s:=])' }).Count) { throw 'Password arguments are forbidden; use a certificate store or hardware token.' }
}
if ($TestHooks) { $env:RooIndustriesTestHooks = 'true' }
elseif ($env:RooIndustriesTestHooks) { throw 'RooIndustriesTestHooks is set in this environment, so this build would contain test hooks. Remove it, or pass -TestHooks to build a test installer on purpose.' }
if ($env:GovernorTestHooks) { throw 'GovernorTestHooks is set in this environment, so this build would contain governor test hooks. Remove it before building a release.' }

$repoRoot = (Resolve-Path (Get-ReleaseToolPath (Join-Path $PSScriptRoot '..\..'))).ProviderPath
Assert-ReleasePathBound -RepoRoot $repoRoot
$releaseTools = Join-Path $repoRoot 'tools\release'
if (-not $PSBoundParameters.ContainsKey('UpdateFeedUrl')) { $UpdateFeedUrl = [IO.File]::ReadAllText((Join-Path $releaseTools 'update-feed.txt')).Trim() }
if ($UpdateFeedUrl) {
    $feedUri = $null
    if (-not [Uri]::TryCreate($UpdateFeedUrl, [UriKind]::Absolute, [ref]$feedUri) -or $feedUri.Scheme -ne 'https') { throw 'UpdateFeedUrl must be an HTTPS URL, or empty to disable updates.' }
}
$appProject = Join-Path $repoRoot 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot 'artifacts\release' }
$OutputRoot = Get-ReleaseToolPath $OutputRoot
$appProject = Get-ReleaseToolPath $appProject
$releaseTools = Get-ReleaseToolPath $releaseTools
$obfuscarVersion = '2.2.50'

function Resolve-DotNetSdk([string]$RequestedPath) {
    $candidates = @($RequestedPath, (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'))
    $command = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath (Get-ReleaseToolPath $candidate))) { continue }
        $sdks = & (Get-ReleaseToolPath $candidate) --list-sdks 2>$null
        if ($LASTEXITCODE -eq 0 -and @($sdks | Where-Object { $_ -match '^8\.' }).Count -gt 0) { return (Resolve-Path -LiteralPath (Get-ReleaseToolPath $candidate)).Path }
    }
    throw 'No dotnet executable with a .NET 8 SDK was found. Pass -DotNetPath or set ROO_INDUSTRIES_DOTNET_EXE.'
}

function Resolve-Iscc([string]$RequestedPath) {
    $candidates = @($RequestedPath, (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'), (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath (Get-ReleaseToolPath $candidate))) { return (Resolve-Path -LiteralPath (Get-ReleaseToolPath $candidate)).Path }
    }
    throw 'Inno Setup 6 was not found. Install it with: winget install JRSoftware.InnoSetup --scope user'
}

function Resolve-SignTool([string]$RequestedPath) {
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath (Get-ReleaseToolPath $RequestedPath) -PathType Leaf)) { throw 'SignToolPath does not name an existing executable.' }
        return (Resolve-Path -LiteralPath (Get-ReleaseToolPath $RequestedPath)).ProviderPath
    }
    $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $candidate = if ([IO.Directory]::Exists((ConvertTo-ReleaseExtendedPath $sdk))) { [IO.Directory]::EnumerateDirectories((ConvertTo-ReleaseExtendedPath $sdk), '10.*') | Sort-Object { [Version][IO.Path]::GetFileName($_) } -Descending | ForEach-Object { $file = Get-ReleaseToolPath (Join-Path $_ 'x64\signtool.exe'); if ([IO.File]::Exists((ConvertTo-ReleaseExtendedPath $file))) { $file } } | Select-Object -First 1 }
    if (-not $candidate) { throw 'signtool.exe was not found. Pass -SignToolPath or set ROO_INDUSTRIES_SIGNTOOL.' }
    return $candidate
}

function Assert-ReleaseSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath (Get-ReleaseToolPath $Path)
    if (-not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $SignSubject) { throw ('Signer subject differs from SignSubject: ' + $Path) }
    $accepted = $signature.Status -eq 'Valid' -or ($AllowUntrustedSignature -and $signature.Status -in @('UnknownError', 'NotTrusted'))
    if (-not $accepted) { throw ('Signature verification failed (' + $signature.Status + '): ' + $Path) }
    return $signature
}

function ConvertTo-InnoSignArgument([string]$Value) {
    if ($Value.Contains("`r") -or $Value.Contains("`n")) { throw 'Signing arguments cannot contain line breaks.' }
    $escaped = $Value.Replace('$', '$$')
    if ($Value -notmatch '[\s"]') { return $escaped }
    $escaped = [regex]::Replace($escaped, '(\\*)"', { param($match) ('\' * ($match.Groups[1].Length * 2 + 1)) + '$q' })
    $escaped = [regex]::Replace($escaped, '\\+$', '$0$0')
    return '$q' + $escaped + '$q'
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments, [string]$Step) {
    $toolArguments = @(Get-ReleaseToolArguments $Arguments)
    & (Get-ReleaseToolPath $FilePath) @toolArguments
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE." }
}

function Copy-Tree([string]$Source, [string]$Destination, [string[]]$Include = @('*'), [string[]]$Exclude = @()) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    Get-ChildItem -LiteralPath (Get-ReleaseToolPath $Source) -File -Recurse | Where-Object {
        $name = $_.Name
        (@($Include | Where-Object { $name -like $_ }).Count -gt 0) -and (@($Exclude | Where-Object { $name -like $_ }).Count -eq 0)
    } | ForEach-Object {
        $target = Join-Path $Destination $_.FullName.Substring($Source.Length).TrimStart('\')
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        Copy-Item -LiteralPath (Get-ReleaseToolPath $_.FullName) -Destination (Get-ReleaseToolPath $target)
    }
}

function Remove-Tree([string]$Path) {
    if (-not (Test-Path -LiteralPath (Get-ReleaseToolPath $Path))) { return }
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push((ConvertTo-ReleaseExtendedPath $Path))
    $directories = [Collections.Generic.List[string]]::new()
    while ($pending.Count) {
        $entry = $pending.Pop(); $attributes = [IO.File]::GetAttributes($entry)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Release removal refuses a reparse point: ' + $entry) }
        if ($attributes -band [IO.FileAttributes]::Directory) { $directories.Add($entry); foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($entry)) { $pending.Push($child) } }
        else { [IO.File]::SetAttributes($entry, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly))); [IO.File]::Delete($entry) }
    }
    foreach ($entry in ($directories | Sort-Object Length -Descending)) { [IO.Directory]::Delete($entry) }
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
        if (-not (Test-Path -LiteralPath (Get-ReleaseToolPath $obfuscated))) { throw "Obfuscar did not produce $module." }
        Copy-Item -LiteralPath (Get-ReleaseToolPath $obfuscated) -Destination (Get-ReleaseToolPath (Join-Path $Directory $module)) -Force
    }
    [IO.Directory]::CreateDirectory($MapDirectory) | Out-Null
    Copy-Item -LiteralPath (Get-ReleaseToolPath (Join-Path $out 'obfuscar-map.xml')) -Destination (Get-ReleaseToolPath (Join-Path $MapDirectory ([IO.Path]::GetFileName($Directory) + '-map.xml'))) -Force
}

$project = [xml](Get-Content -LiteralPath (Get-ReleaseToolPath $appProject) -Raw)
$version = @($project.Project.PropertyGroup | ForEach-Object { $_.SelectSingleNode('Version') } | Where-Object { $_ })[0].InnerText
if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$') { throw "The app project version '$version' is not a release version." }
$numericVersion = '{0}.{1}.{2}.0' -f $Matches[1], $Matches[2], $Matches[3]
Assert-ReleaseVersion $repoRoot $version

$dotnet = Resolve-DotNetSdk $DotNetPath
$iscc = Resolve-Iscc $IsccPath
$signtool = if ($signing) { Resolve-SignTool $SignToolPath } else { $null }
$innoSignCommand = if ($signing) { (ConvertTo-InnoSignArgument $signtool) + ' sign ' + (((Get-ReleaseToolArguments $SignArguments) | ForEach-Object { ConvertTo-InnoSignArgument $_ }) -join ' ') + ' $f' } else { $null }
Write-Host "Version $version using $dotnet and $iscc"
Write-Host ('Bug report webhook: ' + $(if ([string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_BUG_WEBHOOK)) { 'not set, testers save reports to a file' } else { 'embedded from ROO_INDUSTRIES_BUG_WEBHOOK' }))
Write-Host ('Update feed: ' + $(if ($UpdateFeedUrl) { $UpdateFeedUrl } else { 'not set, updates disabled' }))

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
$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:UseSharedCompilation=false', '-p:DebugType=none', '-p:ContinuousIntegrationBuild=true', '-p:GenerateDocumentationFile=false', '-p:RooIndustriesRelease=true')
Invoke-Checked $dotnet (@('publish', (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj'), '-o', $hostOut) + $common) 'Helper publish'
Invoke-Checked $dotnet (@('publish', (Join-Path $repoRoot 'backend\native\Optimizer.SessionHost\Optimizer.SessionHost.csproj'), '-o', $sessionOut) + $common) 'Session helper publish'
Invoke-Checked $dotnet (@('publish', $appProject, '-o', $appOut, '-p:Platform=x64', '-p:WindowsAppSDKSelfContained=true', '-p:WindowsPackageType=None', ('-p:SelfContainedIntermediateOutputPath=' + (Join-Path $work 'wasdk') + '/'),
    ('-p:ApplicationManifest=' + (Join-Path $releaseTools 'app.release.manifest')), ('-p:ROO_INDUSTRIES_UPDATE_FEED=' + $UpdateFeedUrl)) + $common) 'App publish'

$boundedOutputs = @($stage, (Join-Path $work 'wasdk'))
Assert-ReleasePathBound -OutputRoots $boundedOutputs

foreach ($config in @((Join-Path $hostOut 'Optimizer.Host.runtimeconfig.json'), (Join-Path $sessionOut 'RooIndustries.SessionHost.runtimeconfig.json'), (Join-Path $appOut 'RooIndustries.OptimizationSuite.App.runtimeconfig.json'))) {
    if ((Get-Content -LiteralPath (Get-ReleaseToolPath $config) -Raw | ConvertFrom-Json).runtimeOptions.configProperties.'System.StartupHookProvider.IsSupported' -ne $false) { throw ('Startup hooks are not disabled in ' + $config) }
}
$productAssemblies = @((Join-Path $hostOut 'Optimizer.Core.dll'), (Join-Path $hostOut 'Optimizer.Host.dll'), (Join-Path $sessionOut 'RooIndustries.SessionHost.dll'), (Join-Path $appOut 'RooIndustries.OptimizationSuite.App.dll'))
Invoke-Checked $dotnet @('run', '--project', (Join-Path $repoRoot 'tools\validation\DynamicBinding\DynamicBinding.csproj'), '-c', 'Release', '--', '--self-test') 'Dynamic binding guard self-test'
Invoke-Checked $dotnet (@('run', '--project', (Join-Path $repoRoot 'tools\validation\DynamicBinding\DynamicBinding.csproj'), '-c', 'Release', '--') + $productAssemblies) 'Dynamic binding check'

Invoke-Obfuscar $obfuscar $hostOut @('Optimizer.Core.dll', 'Optimizer.Host.dll') $maps
Invoke-Obfuscar $obfuscar $sessionOut @('Optimizer.Core.dll', 'RooIndustries.SessionHost.dll') $maps
Invoke-Obfuscar $obfuscar $appOut @('Optimizer.Core.dll', 'RooIndustries.OptimizationSuite.App.dll') $maps

$backend = Join-Path $repoRoot 'backend'
Copy-ReleaseScripts $repoRoot $stage
Copy-ReleaseData $repoRoot $stage
if($TestHooks){[IO.File]::WriteAllText((Join-Path $stage 'backend\test-hooks.enabled'),'test hooks',[Text.UTF8Encoding]::new($false))}
foreach ($native in @('CpuSets', 'ProcessGovernor', 'ProcessOutput', 'StandbyMemoryHelper')) {
    Copy-Tree (Join-Path $backend "native\$native") (Join-Path $stage "backend\native\$native") @('*.cs')
}
Copy-Tree (Join-Path $repoRoot 'assets\brand\roo-industries') (Join-Path $stage 'assets\brand\roo-industries') @('favicon-96x96.png', 'web-app-manifest-192x192.png', 'embed_logo.png', 'favicon.ico')
[IO.File]::WriteAllText((Join-Path $stage 'README-BETA.txt'), [IO.File]::ReadAllText((Join-Path $releaseTools 'README-BETA.txt')).Replace('{Version}', $version), [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Get-ReleaseToolPath (Join-Path $repoRoot 'CREDITS.md')) -Destination (Get-ReleaseToolPath (Join-Path $stage 'CREDITS.md'))
Copy-Item -LiteralPath (Get-ReleaseToolPath (Join-Path $repoRoot 'LICENSE')) -Destination (Get-ReleaseToolPath (Join-Path $stage 'LICENSE.txt'))

Assert-ReleasePathBound -OutputRoots $boundedOutputs
Get-ChildItem -LiteralPath (Get-ReleaseToolPath $stage) -Recurse -File -Filter '*.pdb' | Remove-Item -Force
foreach ($required in @('app\RooIndustries.OptimizationSuite.App.exe', 'backend\bin\optimizer\Optimizer.Host.exe', 'backend\bin\optimizer\hostpolicy.dll', 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe', 'backend\scripts\Start-RooIndustriesHelper.cmd', 'backend\scripts\Invoke-GovernorSetup.ps1', 'backend\scripts\BrandCompatibility.Common.ps1', 'backend\samples', 'backend\catalogs\windows-tweaks.json', 'app\Microsoft.WindowsAppRuntime.dll', 'app\RooIndustries.OptimizationSuite.App.pri', 'CREDITS.md', 'LICENSE.txt')) {
    if (-not (Test-Path -LiteralPath (Get-ReleaseToolPath (Join-Path $stage $required)))) { throw "The release layout is missing $required." }
}

$unsignedFiles = @()
$setupSignature = $null
if ($signing) {
    $signFiles = @('app\RooIndustries.OptimizationSuite.App.exe', 'app\RooIndustries.OptimizationSuite.App.dll', 'app\Optimizer.Core.dll',
        'backend\bin\optimizer\Optimizer.Host.exe', 'backend\bin\optimizer\Optimizer.Host.dll', 'backend\bin\optimizer\Optimizer.Core.dll',
        'backend\bin\optimizer\session\RooIndustries.SessionHost.exe', 'backend\bin\optimizer\session\RooIndustries.SessionHost.dll', 'backend\bin\optimizer\session\Optimizer.Core.dll')
    $rooNames = @('RooIndustries.OptimizationSuite.App', 'Optimizer.Core', 'Optimizer.Host', 'RooIndustries.SessionHost')
    $peFiles = @(Get-ChildItem -LiteralPath (Get-ReleaseToolPath $stage) -File -Recurse | Where-Object { $_.Extension -in @('.exe', '.dll') })
    foreach ($file in $peFiles) {
        $assemblyName = $file.BaseName
        try { $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($file.FullName).Name } catch [BadImageFormatException] { }
        if ($assemblyName -in $rooNames -or $assemblyName -like 'RooIndustries.*' -or $assemblyName -like 'Optimizer.*') {
            $relative = $file.FullName.Substring($stage.Length + 1)
            if ($relative -notin $signFiles) { $signFiles += $relative }
        }
    }
    $files = @($signFiles | ForEach-Object {
        $path = Get-ReleaseToolPath (Join-Path $stage $_)
        if (-not (Test-Path -LiteralPath (Get-ReleaseToolPath $path) -PathType Leaf)) { throw ('Required signing file is missing: ' + $_) }
        $path
    })
    $toolSignArguments = @(Get-ReleaseToolArguments $SignArguments)
    & (Get-ReleaseToolPath $signtool) sign @toolSignArguments @files
    if ($LASTEXITCODE -ne 0) { throw ('Release signing failed with exit code ' + $LASTEXITCODE + '.') }
    foreach ($file in $files) { Assert-ReleaseSignature $file | Out-Null }
    foreach ($file in $peFiles) {
        $signature = Get-AuthenticodeSignature -LiteralPath (Get-ReleaseToolPath $file.FullName)
        if ($signature.Status -eq 'NotSigned') {
            $relative = $file.FullName.Substring($stage.Length + 1)
            if ($relative -in $signFiles) { throw ('A Roo Industries-built PE is unsigned: ' + $relative) }
            $unsignedFiles += $relative
        }
    }
}

Assert-ReleaseScripts $repoRoot $stage -TestHooks:$TestHooks

$OutputEncoding = [Text.UTF8Encoding]::new($false)
$netVariables = @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)' })
foreach ($variable in $netVariables) { Remove-Item -LiteralPath ('Env:\' + $variable.Name) }
try { $smoke = ((@{ schemaVersion = 1; repoRoot = $stage } | ConvertTo-Json) | & (Get-ReleaseToolPath (Join-Path $hostOut 'Optimizer.Host.exe')) 'tweak-catalog' '-') -join "`n" }
finally { foreach ($variable in $netVariables) { Set-Item -LiteralPath ('Env:\' + $variable.Name) -Value $variable.Value } }
if ($LASTEXITCODE -ne 0 -or $smoke -notmatch '"status"\s*:\s*"completed"' -or $smoke -notmatch '"settings"\s*:\s*\[\s*\{') { throw 'The obfuscated helper could not read the Windows tweak catalog.' }
Write-Host ('Smoke test: the obfuscated helper returned the Windows tweak catalog (' + $smoke.Length + ' characters).')

[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$setupName = "RooIndustries-OptimizationSuite-$version-setup"
$governorSetupHash = (Get-FileHash -LiteralPath (Get-ReleaseToolPath (Join-Path $stage 'backend\scripts\Invoke-GovernorSetup.ps1')) -Algorithm SHA256).Hash
$governorSetupCommonHash = (Get-FileHash -LiteralPath (Get-ReleaseToolPath (Join-Path $stage 'backend\scripts\BrandCompatibility.Common.ps1')) -Algorithm SHA256).Hash
$isccArguments = @('/Q', "/DAppVersion=$version", "/DGovernorSetupHash=$governorSetupHash", "/DGovernorSetupCommonHash=$governorSetupCommonHash", "/DAppNumericVersion=$numericVersion", "/DSourceDir=$stage", "/DOutputDir=$OutputRoot", "/DOutputName=$setupName", (Join-Path $releaseTools 'RooIndustries.OptimizationSuite.iss'))
if ($signing) { $isccArguments += @('/DSignInstaller=1', ('/Sroosign=' + $innoSignCommand)) }
Invoke-Checked $iscc $isccArguments 'Installer build'
$setup = Join-Path $OutputRoot ($setupName + '.exe')
if ($signing) { $setupSignature = Assert-ReleaseSignature $setup }
$hash = (Get-FileHash -LiteralPath (Get-ReleaseToolPath $setup) -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($setup + '.sha256', $hash + '  ' + [IO.Path]::GetFileName($setup) + "`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ version = $version; installer = $setup; bytes = (Get-Item -LiteralPath (Get-ReleaseToolPath $setup)).Length; sha256 = $hash; stage = $stage; obfuscationMaps = $maps; signed = $signing; signerSubject = if ($setupSignature) { $setupSignature.SignerCertificate.Subject } else { $null }; signerThumbprint = if ($setupSignature) { $setupSignature.SignerCertificate.Thumbprint } else { $null }; signatureStatus = if ($setupSignature) { [string]$setupSignature.Status } else { 'NotSigned' }; unsignedFiles = $unsignedFiles } | ConvertTo-Json
