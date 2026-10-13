param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[switch]$HeapProbe)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Memory\Memory.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'memory-build' $OutRoot
Assert-HarnessHostLease;Ensure-HarnessOutputDirectory $OutRoot;Initialize-HarnessBuildFolders $Source
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:ROO_INDUSTRIES_SIGN_ARGS_JSON='';$env:ROO_INDUSTRIES_BUG_WEBHOOK='';$env:RooIndustriesTestHooks='';$env:GovernorTestHooks='';$env:ROO_HARNESS_NONCE=$nonce
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$startedAt=[DateTime]::UtcNow
try{
 $output=Join-Path $OutRoot 'release';New-HarnessDirectory $output 'release-output'|Out-Null
 $command="& '"+(Get-HarnessToolPath (Join-Path $Source 'tools\scripts\Build-Release.ps1'))+"' -OutputRoot '"+(Get-HarnessToolPath $output)+"' -UpdateFeedUrl ''"
 Invoke-HarnessProcess (Get-HarnessToolPath $ps) ('-NoProfile -ExecutionPolicy Bypass -Command "'+$command+'"') 'memory-build'|Out-Null
 $version=([xml][IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj')))).SelectSingleNode('//Version').InnerText
 $stage=Join-Path $output ('work-'+$version+'\stage');$installer=Join-Path $output ('RooIndustries-OptimizationSuite-'+$version+'-setup.exe')
 $probe=Join-Path $OutRoot 'probe';New-HarnessDirectory $probe 'probe-output'|Out-Null
 Invoke-HarnessProcess (Get-HarnessToolPath $dotnet) ('publish "'+(Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\UpdateProbe\UpdateProbe.csproj'))+'" -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o "'+(Get-HarnessToolPath $probe)+'"') 'memory-probe-build'|Out-Null
 $result=Get-HarnessOutputPath $OutRoot 'embedded-feed.json'
 Invoke-HarnessProcess (Get-HarnessToolPath (Join-Path $probe 'UpdateProbe.exe')) ('--embedded-feed "'+(Get-HarnessToolPath (Join-Path $stage 'app\RooIndustries.OptimizationSuite.App.dll'))+'" "'+(Get-HarnessToolPath $result)+'"') 'memory-empty-feed'|Out-Null
 Register-HarnessFile $result 'result'|Out-Null;$embedded=Read-HarnessResult $result $nonce
 if($embedded.feed -cne 'url='){throw ('Updates were not disabled: '+$embedded.feed)}
 $heapExe=''
 if($HeapProbe){
  $heap=Join-Path $OutRoot 'heap';New-HarnessDirectory $heap 'heap-output'|Out-Null
  $project=Join-Path $Source 'tools\validation\Memory\HeapProbe\HeapProbe.csproj'
  Invoke-HarnessProcess (Get-HarnessToolPath $dotnet) ('publish "'+(Get-HarnessToolPath $project)+'" -c Release -r win-x64 --self-contained true -p:UseSharedCompilation=false -o "'+(Get-HarnessToolPath $heap)+'"') 'memory-heap-build'|Out-Null
  $heapExe=Join-Path $heap 'HeapProbe.exe'
 }
 $files=@(Get-HarnessTree $stage -FilesOnly|ForEach-Object {@{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');bytes=$_.Length;sha256=Get-HarnessFileSha256 $_.LongPath}})
 Write-HarnessResult $OutRoot 'payload-hashes.json' @{files=$files;installerSha256=Get-HarnessFileSha256 $installer}|Out-Null
 Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';version=$version;installer=$installer;bytes=(Get-HarnessItem $installer).Length;sha256=Get-HarnessFileSha256 $installer;stage=$stage;feed=$embedded.feed;heap=$heapExe;seconds=$clock.Elapsed.TotalSeconds}|Out-Null
 foreach($candidate in Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -ne $PID -and $_.CreationDate.ToUniversalTime() -ge $startedAt}){Test-OwnedDescendant ([int]$candidate.ProcessId) -PassThru|Out-Null}
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
}catch{Complete-HarnessInvocation 'fail' -Cleanup|Out-Null;throw}
