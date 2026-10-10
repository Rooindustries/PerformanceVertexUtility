param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidateSet('production-build','regressions')][string]$Phase,[string]$Stage='',[string]$LeadCheckPath='',[string]$LeadCheckHash='')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$env:ROO_INDUSTRIES_BUG_WEBHOOK='';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:UseSharedCompilation='false'
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $OutRoot ($name+'.json')),($value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
if($Phase -eq 'production-build'){
 $failures=@();foreach($file in @(Get-ChildItem (Join-Path $Source 'backend\scripts') -Filter '*.ps1')+@(Get-ChildItem (Join-Path $Source 'tools\validation') -Filter '*.ps1' -Recurse)){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null;foreach($error in $errors){$failures+=@{file=$file.FullName;line=$error.Extent.StartLineNumber;message=$error.Message}}};Save 'parse-errors' @($failures);if($failures.Count){throw 'PowerShell parse failed'}
 $clock=[Diagnostics.Stopwatch]::StartNew();& (Join-Path $Source 'tools\scripts\Build-Release.ps1') -OutputRoot (Join-Path $OutRoot 'release') *> (Join-Path $OutRoot 'build.log');if(-not$? -or $LASTEXITCODE -ne 0){throw 'Production build failed'};$clock.Stop()
 $stage=Join-Path $OutRoot 'release\work-0.11.0-beta\stage';$exe=Join-Path $OutRoot 'release\RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe'
 & $dotnet publish (Join-Path $Source 'tools\validation\Update\UpdateProbe\UpdateProbe.csproj') -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o (Join-Path $OutRoot 'probe') *> (Join-Path $OutRoot 'probe-build.log');if($LASTEXITCODE -ne 0){throw 'Probe build failed'}
 $probe=Join-Path $OutRoot 'probe\UpdateProbe.exe'
 & $probe --embedded-feed (Join-Path $stage 'app\RooIndustries.OptimizationSuite.App.dll') (Join-Path $OutRoot 'embedded-feed.json');if($LASTEXITCODE -ne 0){throw 'Embedded feed read failed'}
 $resource=Get-Content -Raw (Join-Path $OutRoot 'embedded-feed.json')|ConvertFrom-Json
 if($resource.feed -cne ('url='+[IO.File]::ReadAllText((Join-Path $Source 'tools\release\update-feed.txt')).Trim())){throw 'Production resource differs from the committed feed'}
 & $probe --install-space 'C:\Program Files\Roo Industries\Optimization Suite\app' (Join-Path $OutRoot 'install-space.json');if($LASTEXITCODE -ne 0){throw 'Space comparison failed'}
 Save 'build-result' @{exitCode=0;seconds=$clock.Elapsed.TotalSeconds;installer=$exe;stage=$stage;bytes=(Get-Item $exe).Length;sha256=(Get-FileHash $exe).Hash;embeddedFeed=$resource.feed;machine=$env:COMPUTERNAME}
 return
}
$rows=[Collections.Generic.List[object]]::new()
function Suite([string]$name,[string]$script,[string[]]$arguments=@()){
 $clock=[Diagnostics.Stopwatch]::StartNew();$log=Join-Path $OutRoot ($name+'.log');$errorLog=Join-Path $OutRoot ($name+'-error.log')
 $quoted=@($script)+$arguments|ForEach-Object {'"'+$_.Replace('"','\"')+'"'}
 $p=Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+($quoted -join ' ')) -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $errorLog -PassThru;$receipt=New-OwnedProcess $p
 try{if(-not$p.WaitForExit(1200000)){throw ('Suite timed out: '+$name)};$p.Refresh();$text=[IO.File]::ReadAllText($log);$passed=$p.ExitCode -eq 0 -and $text -notmatch '(?m)^FAIL\b';$rows.Add(@{name=$name;passed=$passed;exitCode=$p.ExitCode;seconds=$clock.Elapsed.TotalSeconds;passLines=@($text -split "`n"|Where-Object {$_ -match '^PASS\b'}).Count;log=$log;errorLog=$errorLog});Save 'suites' @($rows.ToArray());Write-Output (($(if($passed){'PASS'}else{'FAIL'}))+' '+$name)}finally{Stop-OwnedProcess $receipt;$p.Dispose()}
}
if(-not$LeadCheckPath -or (Get-FileHash $LeadCheckPath).Hash -ine $LeadCheckHash){throw 'Lead check bytes differ'}
Suite 'lead-priority-13' $LeadCheckPath @('-Source',$Source,'-OutRoot',(Join-Path $OutRoot 'lead-priority'),'-Stage',$Stage)
foreach($name in 'Test-ProcessProfileBackend','Test-GameTuneSessionRuntime','Test-ProcessGovernorRuntime'){Suite $name (Join-Path $Source ('backend\scripts\'+$name+'.ps1'))}
Suite 'Test-ProtectedGameSessions' (Join-Path $Source 'backend\scripts\Test-ProtectedGameSessions.ps1') @('-DotNetPath',$dotnet)
Suite 'Test-ProtectedGameSessions-RetainedGpu' (Join-Path $Source 'backend\scripts\Test-ProtectedGameSessions.ps1') @('-DotNetPath',$dotnet,'-RetainedGpu')
foreach($area in 'process-controls','policies','control-reads'){Suite ('Test-OptimizerCore-'+$area) (Join-Path $Source 'backend\scripts\Test-OptimizerCore.ps1') @('-DotNetPath',$dotnet,'-Area',$area)}
$native=Join-Path $OutRoot 'run-services.ps1';[IO.File]::WriteAllText($native,('$ErrorActionPreference=''Stop''; & '''+$dotnet+''' run --project '''+(Join-Path $Source 'tools\validation\Tweaks\Tweaks.csproj')+''' --configuration Release -p:UseSharedCompilation=false -- '''+$Source+''' --controls-fixture; exit $LASTEXITCODE'),[Text.UTF8Encoding]::new($false));Suite 'Test-Tweaks-controls-fixture' $native
if(@($rows|Where-Object {-not$_.passed}).Count){throw 'Final regression gate failed; inspect suites.json'}
