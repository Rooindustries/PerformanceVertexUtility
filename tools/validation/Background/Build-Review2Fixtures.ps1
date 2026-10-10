param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Stage,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
& $dotnet publish (Join-Path $Source 'tools\validation\ClientBoundary\ClientBoundary.csproj') -c Release -p:UseSharedCompilation=false -r win-x64 --self-contained false -o (Join-Path $OutRoot 'client-probe') *> (Join-Path $OutRoot 'client-probe-build.log')
if($LASTEXITCODE){throw 'Review2 client service probe build failed'}
$copy=Join-Path $OutRoot 'timer-app'
Copy-Item -LiteralPath $Stage -Destination $copy -Recurse
$fixtureSource=Join-Path $OutRoot 'timer-source'
foreach($file in Get-ChildItem (Join-Path $Source 'backend\native') -File -Recurse){
 $relative=$file.FullName.Substring($Source.Length).TrimStart('\')
 if($relative -match '(^|\\)(obj|bin)(\\|$)'){continue}
 $destination=Join-Path $fixtureSource $relative;[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null;Copy-Item $file.FullName $destination
}
foreach($relative in 'backend\catalogs\adobe-hosts.txt','tools\release\update-keys.json'){$destination=Join-Path $fixtureSource $relative;[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null;Copy-Item (Join-Path $Source $relative) $destination}
$timerPath=Join-Path $fixtureSource 'backend\native\Optimizer.Core\TimerControl.cs'
$text=[IO.File]::ReadAllText($timerPath)
$pattern='(?s)    public static TweakControlRead Read\(ControlAddress address\)\s*\{.*?(?=    public static void Write)'
if([regex]::Matches($text,$pattern).Count -ne 1){throw 'Timer fixture read-method boundary differs'}
$replacement='    public static TweakControlRead Read(ControlAddress address) { throw new InvalidDataException("Fixture timer interval cannot be read."); }'+[Environment]::NewLine
[IO.File]::WriteAllText($timerPath,[regex]::Replace($text,$pattern,$replacement),[Text.UTF8Encoding]::new($false))
& $dotnet build (Join-Path $fixtureSource 'backend\native\Optimizer.Core\Optimizer.Core.csproj') -c Release -p:RooIndustriesRelease=true -p:UseSharedCompilation=false -o (Join-Path $OutRoot 'timer-core') *> (Join-Path $OutRoot 'timer-core-build.log')
if($LASTEXITCODE){throw 'Timer fixture Core build failed'}
Copy-Item (Join-Path $OutRoot 'timer-core\Optimizer.Core.dll') (Join-Path $copy 'app\Optimizer.Core.dll') -Force
@{clientProbe=(Join-Path $OutRoot 'client-probe\ClientBoundary.exe');timerApp=(Join-Path $copy 'app\RooIndustries.OptimizationSuite.App.exe');coreHookOnly=$true;timerFaultSource=$timerPath;timerFaultSha256=(Get-FileHash $timerPath).Hash;stage=$Stage}|ConvertTo-Json|Set-Content (Join-Path $OutRoot 'fixtures.json')
