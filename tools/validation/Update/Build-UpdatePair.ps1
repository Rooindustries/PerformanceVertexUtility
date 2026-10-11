param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][string]$FeedUrl,[Parameter(Mandatory)][string]$VersionA,[Parameter(Mandatory)][string]$VersionB)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'Build-UpdatePair' $OutputRoot
Ensure-HarnessOutputDirectory $OutputRoot
$buildStarted=[DateTime]::UtcNow

$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:ROO_INDUSTRIES_BUG_WEBHOOK=''
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
$copy=Join-Path $OutputRoot 'source-B'
New-HarnessDirectory $copy 'build-source'|Out-Null
foreach($file in Get-ChildItem -LiteralPath $Source -File -Recurse){
 $relative=$file.FullName.Substring($Source.Length).TrimStart('\')
 if($relative -match '(^|\\)(obj|bin|artifacts|\.git)(\\|$)' -or $relative -eq 'source-verification.json'){continue}
 $destination=Join-Path $copy $relative;[IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
 Copy-Item -LiteralPath $file.FullName -Destination $destination
}
$project=Join-Path $copy 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
$text=[IO.File]::ReadAllText($project)
$pattern='<Version>'+[regex]::Escape($VersionA)+'</Version>'
if([regex]::Matches($text,$pattern).Count -ne 1){throw 'Build A Version differs from the selected source version'}
[IO.File]::WriteAllText($project,[regex]::Replace($text,$pattern,('<Version>'+$VersionB+'</Version>')),[Text.UTF8Encoding]::new($false))
$rows=@()
foreach($build in @(@{name='A';source=$Source},@{name='B';source=$copy})){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $build.source 'tools\scripts\Build-Release.ps1')+'" -OutputRoot "'+(Join-Path $OutputRoot $build.name)+'" -UpdateFeedUrl "'+$FeedUrl+'"') ('build-'+$build.name)|Out-Null
 $clock.Stop();$rows+=@{build=$build.name;seconds=$clock.Elapsed.TotalSeconds;source=$build.source;feed=$FeedUrl}
}
Invoke-HarnessProcess $dotnet ('publish "'+(Join-Path $Source 'tools\validation\Update\UpdateProbe\UpdateProbe.csproj')+'" -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o "'+(Join-Path $OutputRoot 'probe')+'"') 'build-probe'|Out-Null
Write-HarnessResult $OutputRoot 'build-times.json' $rows|Out-Null
Register-HarnessGeneratedFolders $Source $buildStarted
Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
