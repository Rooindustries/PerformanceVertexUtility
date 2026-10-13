param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[switch]$ProbeOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'release-candidate-build' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
Initialize-HarnessBuildFolders $Source
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
$env:ROO_INDUSTRIES_SIGN_ARGS_JSON=''
$env:ROO_INDUSTRIES_BUG_WEBHOOK=''
$env:RooIndustriesTestHooks=''
$env:ROO_HARNESS_NONCE=$nonce
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$clock=[Diagnostics.Stopwatch]::StartNew()
try{
 if(-not$ProbeOnly){
  $feed=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'tools\release\update-feed.txt'))).Trim()
  $output=Join-Path $OutRoot 'release';New-HarnessDirectory $output 'release-output'|Out-Null
  Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -ExecutionPolicy Bypass -File "'+(Get-HarnessToolPath (Join-Path $Source 'tools\scripts\Build-Release.ps1'))+'" -OutputRoot "'+(Get-HarnessToolPath $output)+'" -UpdateFeedUrl "'+$feed+'"') 'candidate-release-build'|Out-Null
  $project=[xml][IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj')))
  $version=$project.SelectSingleNode('//Version').InnerText
  $stage=Join-Path $output ('work-'+$version+'\stage')
  $installer=Join-Path $output ('RooIndustries-OptimizationSuite-'+$version+'-setup.exe')
  $files=@(Get-HarnessTree $stage -FilesOnly|ForEach-Object {@{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');bytes=$_.Length;sha256=Get-HarnessFileSha256 $_.LongPath}})
  Write-HarnessResult $OutRoot 'payload-hashes.json' @{installerSha256=Get-HarnessFileSha256 $installer;installerSize=(Get-HarnessItem $installer).Length;files=$files}|Out-Null
 }
 $probe=Join-Path $OutRoot 'probe';New-HarnessDirectory $probe 'probe-output'|Out-Null
 Invoke-HarnessProcess $dotnet ('publish "'+(Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\UpdateProbe\UpdateProbe.csproj'))+'" -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o "'+(Get-HarnessToolPath $probe)+'"') 'candidate-probe-build'|Out-Null
 if(-not$ProbeOnly){
  $result=Get-HarnessOutputPath $OutRoot 'embedded-feed.json'
  Invoke-HarnessProcess (Join-Path $probe 'UpdateProbe.exe') ('--embedded-feed "'+(Get-HarnessToolPath (Join-Path $stage 'app\RooIndustries.OptimizationSuite.App.dll'))+'" "'+(Get-HarnessToolPath $result)+'"') 'candidate-embedded-feed'|Out-Null
  Register-HarnessFile $result 'result' 'run'|Out-Null;$embedded=Read-HarnessResult $result $nonce
  if($embedded.feed -cne ('url='+$feed)){throw 'Candidate embedded feed differs from the committed feed.'}
  if((Get-HarnessItem $installer).VersionInfo.ProductVersion.TrimEnd(' ') -cne $version){throw 'Candidate ProductVersion differs from source.'}
  $clock.Stop()
  Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';version=$version;numericVersion=($version.Split('-')[0]+'.0');installer=$installer;bytes=(Get-HarnessItem $installer).Length;sha256=Get-HarnessFileSha256 $installer;stage=$stage;feed=$embedded.feed.Substring(4);embeddedResource=$embedded.feed;signed=$false;seconds=$clock.Elapsed.TotalSeconds;files=$files.Count}|Out-Null
 }
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
}catch{
 Complete-HarnessInvocation 'fail' -Cleanup|Out-Null
 throw
}
