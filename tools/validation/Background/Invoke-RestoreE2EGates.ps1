param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string]$ReceiptPath='',[string[]]$Scenario=@(),[ValidateSet('default','harness-blocked')][string]$Group='default')
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not[Environment]::Is64BitProcess){throw 'These required manual E2E gates need Windows PowerShell5.1 x64.'}
foreach($command in 'Assert-FrameSourceSnapshot','Assert-ProtectedFrame','Assert-PlainAncestry','Get-HarnessPlainPath','Get-HarnessLongPath','Get-HarnessTree','Get-HarnessFileSha256'){
 if(-not(Get-Command $command -ErrorAction SilentlyContinue)){throw ('The caller must supply the existing verified windows_ssh REMOTE_GUARDS recipe in this PowerShell session; missing '+$command+'.')}
}
if(-not $ReceiptPath){$ReceiptPath=Join-Path $OutRoot 'frame-receipt.json'}
Assert-PlainAncestry $ReceiptPath
$receipt=[IO.File]::ReadAllText((Get-HarnessLongPath $ReceiptPath))|ConvertFrom-Json
$Source=(Get-HarnessPlainPath $Source).TrimEnd('\');$OutRoot=(Get-HarnessPlainPath $OutRoot).TrimEnd('\')
if($receipt.stagingPath -ine $Source -or $receipt.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $receipt.manifestSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $receipt.frameId -cnotmatch '^[a-f0-9]{32}$' -or $receipt.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $receipt.machine -cne $env:COMPUTERNAME){throw 'Original frame receipt/source/actor binding changed.'}
$frame=(Get-HarnessPlainPath ([string]$receipt.runRoot)).TrimEnd('\')
if($frame -notmatch '^C:\\RooBuild\\roo-industries-[A-Za-z0-9_-]+-[a-f0-9]{32}$' -or -not $frame.EndsWith('-'+$receipt.frameId,[StringComparison]::Ordinal) -or [IO.Path]::GetDirectoryName($Source) -ine $frame -or [IO.Path]::GetFileName($Source) -cne 'source' -or -not $OutRoot.StartsWith($frame+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source/output paths escape the original GUID frame.'}
function Assert-E2ECurrentSource{
 $manifest=Assert-FrameSourceSnapshot $Source $receipt.manifestSha256
 $count=@($manifest.files.PSObject.Properties).Count
 if($manifest.protocol -cne 'roo-industries-source-snapshot/v2' -or $manifest.commit -cne $receipt.sourceCommit -or $manifest.frameId -cne $receipt.frameId -or $manifest.sid -cne $receipt.sid -or $manifest.machine -cne $receipt.machine -or $count -le 0 -or $count -ne $receipt.sourceFileCount){throw 'Verified current source protocol/commit/frame/SID/machine/file count differs from original receipt.'}
 return $manifest
}
$initialSource=Assert-E2ECurrentSource
Assert-ProtectedFrame $OutRoot
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
Open-HarnessRun $receipt.runRoot $receipt.frameId $receipt.manifestSha256 $receipt.frameId
Assert-HarnessHostLease
function Get-E2EOwnedFolder([string]$path){
 Assert-ProtectedFrame $path
 $identity=Get-HarnessFolderIdentity $path
 $entries=@(Get-HarnessEntries|Where-Object {$_.state -ceq 'active' -and $_.kind -ceq 'folder' -and (Get-HarnessPlainPath ([string]$_.identity.path)) -ieq $path})
 if($entries.Count -ne 1 -or $entries[0].identity.creationTimeFileTimeUtc -cne $identity.creationTimeFileTimeUtc){throw ('Missing/ambiguous original active folder identity: '+$path)}
 return $identity
}
$outputIdentity=Get-E2EOwnedFolder $OutRoot
$compiledDirectories=@((Join-Path $OutRoot 'compiled\actor'),(Join-Path $OutRoot 'compiled\ui'))
$compiledIdentities=@($compiledDirectories|ForEach-Object {Get-E2EOwnedFolder $_})
$actor=Join-Path $compiledDirectories[0] 'NativeRestoreContention.exe'
$app=Join-Path $compiledDirectories[1] 'AppSweepUi.exe'
$inputPath=Join-Path $OutRoot 'e2e-inputs.json'
Assert-PlainAncestry $inputPath
$inputEntries=@(Get-HarnessEntries|Where-Object {$_.kind -ceq 'file' -and $_.state -ceq 'active' -and (Get-HarnessPlainPath ([string]$_.identity.path)) -ieq $inputPath})
if($inputEntries.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$inputEntries[0].identity.id) -or $inputEntries[0].identity.hash -notmatch '^[a-fA-F0-9]{64}$'){throw 'e2e-inputs.json requires its original unambiguous active Harness file entry and identity/hash.'}
$inputProbe=$null;$bodyError=$null;$cleanupError=$null;$directory=$null
try{
 $inputProbe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $inputPath),$inputEntries[0].identity.id,$inputEntries[0].identity.hash)
 $inputText=$inputProbe.ReadText();$inputs=$inputText|ConvertFrom-Json
 if($inputs.sourceCommit -cne $receipt.sourceCommit -or $inputs.originalSourceCommit -cne 'b0dbcd240953fbf1b87ef0e1d6c15afa44152cb1' -or $inputs.reviewedSourceCommit -cne 'c50c8c8c9a0c8bd2d9103dc0059d088f79a85964'){throw 'Current/original source binding changed.'}
 $bindings=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($binding in @($inputs.files)){
  if($binding.path -isnot [string] -or -not [IO.Path]::IsPathRooted($binding.path) -or $binding.sha256 -isnot [string] -or $binding.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Malformed original input file binding.'}
  $path=Get-HarnessPlainPath $binding.path
  if($path -ine $binding.path -or [RooIndustriesValidationOwnership.Native]::StreamOffset($path) -ge 0 -or -not $path.StartsWith($OutRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $bindings.ContainsKey($path)){throw 'Input path alias/traversal/duplicate or escape refused.'}
  Assert-PlainAncestry $path;Assert-ProtectedFrame ([IO.Path]::GetDirectoryName($path))
  if(-not(Test-HarnessPath $path -PathType Leaf) -or (Get-HarnessFileSha256 $path) -ine $binding.sha256){throw ('Original input file bytes changed: '+$path)}
  $bindings.Add($path,$binding)
 }
 if($bindings.Count -eq 0){throw 'Empty executable/source input binding.'}
 function Assert-E2ECompiledFiles{
  $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($identity in $compiledIdentities){
   $now=Get-E2EOwnedFolder $identity.path
   if($now.creationTimeFileTimeUtc -cne $identity.creationTimeFileTimeUtc){throw 'Compiled directory identity changed.'}
   foreach($file in @(Get-HarnessTree $identity.path -FilesOnly)){
    Assert-PlainAncestry $file.FullName
    if(-not $actual.Add($file.FullName) -or -not $bindings.ContainsKey($file.FullName)){throw ('Published file missing or duplicated in original inputs: '+$file.FullName)}
   }
  }
  foreach($path in $bindings.Keys){
   if(@($compiledDirectories|Where-Object {$path.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -and -not $actual.Contains($path)){throw ('Bound published file is missing: '+$path)}
   Assert-PlainAncestry $path
   if((Get-HarnessFileSha256 $path) -ine $bindings[$path].sha256){throw ('Executed/input bytes changed: '+$path)}
  }
  foreach($entry in $actor,$app){
   $stem=[IO.Path]::Combine([IO.Path]::GetDirectoryName($entry),[IO.Path]::GetFileNameWithoutExtension($entry))
   foreach($required in $entry,($stem+'.dll'),($stem+'.runtimeconfig.json'),($stem+'.deps.json')){
    if(-not $actual.Contains($required) -or -not $bindings.ContainsKey($required)){throw ('Missing required apphost/entry DLL/runtime launch binding: '+$required)}
   }
  }
  return $actual.Count
 }
 $publishedCount=Assert-E2ECompiledFiles
 $originalSource=Get-HarnessPlainPath ([string]$inputs.originalSource)
 $originalManifestPath=Get-HarnessPlainPath ([string]$inputs.originalSourceManifest)
 if(-not $originalSource.StartsWith($OutRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $bindings.ContainsKey($originalManifestPath)){throw 'Original source export/manifest escapes or lacks its original hash binding.'}
 $originalIdentity=Get-E2EOwnedFolder $originalSource
 if($inputs.reviewedSourceCommit -cne 'c50c8c8c9a0c8bd2d9103dc0059d088f79a85964' -or $inputs.reviewedSource -isnot [string] -or $inputs.reviewedSourceManifest -isnot [string] -or ($inputs.reviewedSourceFileCount -isnot [int] -and $inputs.reviewedSourceFileCount -isnot [long]) -or $inputs.reviewedSourceFileCount -le 0){throw 'Malformed reviewed c50 input binding.'}
 $reviewedSource=(Get-HarnessPlainPath $inputs.reviewedSource).TrimEnd('\')
 $reviewedManifestPath=Get-HarnessPlainPath $inputs.reviewedSourceManifest
 if($reviewedSource -ine $inputs.reviewedSource -or $reviewedManifestPath -ine $inputs.reviewedSourceManifest -or -not $reviewedSource.StartsWith($OutRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $reviewedManifestPath.StartsWith($OutRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $bindings.ContainsKey($reviewedManifestPath) -or $reviewedSource -ieq $originalSource){throw 'Reviewed c50 path/manifest alias, separation or binding refused.'}
 Assert-PlainAncestry $reviewedSource;Assert-PlainAncestry $reviewedManifestPath
 $reviewedIdentity=Get-E2EOwnedFolder $reviewedSource
 function Assert-E2EOriginalSource([string]$Export=$originalSource,[string]$ManifestPath=$originalManifestPath,[string]$Commit=$inputs.originalSourceCommit,[int]$FileCount=$inputs.originalSourceFileCount){
  Assert-ProtectedFrame $Export;Assert-PlainAncestry $ManifestPath
  $manifest=[IO.File]::ReadAllText((Get-HarnessLongPath $ManifestPath))|ConvertFrom-Json
  $files=@($manifest.files.PSObject.Properties)
  if($manifest.commit -cne $Commit -or $files.Count -le 0 -or $files.Count -ne $FileCount){throw 'Original b0 source commit/count differs from the original input binding.'}
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($file in $files){
   $path=Get-HarnessPlainPath (Join-Path $Export $file.Name)
   if(-not $path.StartsWith($Export+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $seen.Add($path) -or $file.Value -notmatch '^[a-fA-F0-9]{64}$'){throw 'Original source manifest traversal/alias/duplicate refused.'}
   Assert-PlainAncestry $path
   if((Get-HarnessFileSha256 $path) -ine $file.Value){throw ('Original b0 export bytes changed: '+$file.Name)}
  }
  $actual=@(Get-HarnessTree $Export -FilesOnly)
  if($actual.Count -ne $files.Count){throw 'Original b0 export file count differs from its bound manifest.'}
  foreach($file in $actual){if(-not $seen.Contains($file.FullName)){throw 'Unbound original export file.'}}
  return $files.Count
 }
 $originalCount=Assert-E2EOriginalSource
 $reviewedCount=Assert-E2EOriginalSource $reviewedSource $reviewedManifestPath $inputs.reviewedSourceCommit $inputs.reviewedSourceFileCount
 $directory=Join-Path $OutRoot ('g-'+[guid]::NewGuid().ToString('N').Substring(0,16))
 $null=New-HarnessDirectory $directory 'restore-e2e-artifacts' 'frame'
 $legacy=Join-Path $directory 'legacy';$native=Join-Path $directory 'native';$output=Join-Path $directory 'output'
 foreach($path in $legacy,$native,$output){$null=New-HarnessDirectory $path 'restore-e2e-group' 'frame'}
 & (Join-Path $Source 'tools\validation\Background\Test-RestoreKeepsOtherValue.ps1') -Source $Source -OutRoot $legacy
 if(-not [IO.File]::Exists((Join-Path $legacy 'summary.json'))){throw 'Legacy group lacks its asserted completion artifact.'}
 $parameters=@{Source=$Source;OutRoot=$native;ActorExe=$actor;SourceCommit=$receipt.sourceCommit;OriginalSource=$originalSource;ReviewedSource=$reviewedSource}
 if($Scenario.Count){$parameters.Scenario=$Scenario}else{$parameters.Group=$Group}
 & {. (Join-Path $Source 'tools\validation\Background\Test-RestoreSerialization.ps1') @parameters}
 $summary=Get-Content -LiteralPath (Join-Path $native 'serialization-summary.json') -Raw|ConvertFrom-Json
 if(-not$summary.passed -or @($summary.cases).Count -eq 0 -or $summary.actualCaseCount -ne $summary.expectedCaseCount -or @($summary.selectedTriples).Count -ne @($summary.cases).Count){throw 'Native group lacks asserted cleanup/completion.'}
 & {. (Join-Path $Source 'tools\validation\Background\Test-RestoreSummaryOutput.ps1') -Source $Source -OutRoot $output -AppSweepExe $app}
 Assert-HarnessHostLease
 $finalSource=Assert-E2ECurrentSource
 $finalInputEntries=@(Get-HarnessEntries|Where-Object {$_.kind -ceq 'file' -and $_.state -ceq 'active' -and (Get-HarnessPlainPath ([string]$_.identity.path)) -ieq $inputPath})
 if($finalInputEntries.Count -ne 1 -or $finalInputEntries[0].id -cne $inputEntries[0].id -or $finalInputEntries[0].identity.id -cne $inputEntries[0].identity.id -or $finalInputEntries[0].identity.hash -cne $inputEntries[0].identity.hash){throw 'Original active input ledger entry changed during execution.'}
 if((Assert-E2ECompiledFiles) -ne $publishedCount -or (Assert-E2EOriginalSource) -ne $originalCount -or (Assert-E2EOriginalSource $reviewedSource $reviewedManifestPath $inputs.reviewedSourceCommit $inputs.reviewedSourceFileCount) -ne $reviewedCount -or $inputProbe.ReadText() -cne $inputText){throw 'Post-group original source/artifact binding changed.'}
 foreach($exportIdentity in $originalIdentity,$reviewedIdentity){
  $exportNow=Get-E2EOwnedFolder $exportIdentity.path
  if($exportNow.creationTimeFileTimeUtc -cne $exportIdentity.creationTimeFileTimeUtc){throw 'Original b0/reviewed c50 export ownership changed.'}
 }
 $now=Get-E2EOwnedFolder $OutRoot
 if($now.creationTimeFileTimeUtc -cne $outputIdentity.creationTimeFileTimeUtc){throw 'Original output root identity changed.'}
}catch{$bodyError=$_.Exception}
finally{if($inputProbe){try{$inputProbe.Dispose()}catch{$cleanupError=$_.Exception}}}
if($bodyError -and $cleanupError){throw [AggregateException]::new([Exception[]]@($bodyError,$cleanupError))}
if($bodyError){[Runtime.ExceptionServices.ExceptionDispatchInfo]::Capture($bodyError).Throw()}
if($cleanupError){[Runtime.ExceptionServices.ExceptionDispatchInfo]::Capture($cleanupError).Throw()}
$null=New-HarnessText (Join-Path $directory 'gates.json') (@{sourceCommit=$receipt.sourceCommit;manifestSha256=$receipt.manifestSha256;frameId=$receipt.frameId;sourceFileCount=@($finalSource.files.PSObject.Properties).Count;originalSourceFileCount=$originalCount;reviewedSourceCommit=$inputs.reviewedSourceCommit;reviewedSourceFileCount=$reviewedCount;reviewedManifestSha256=$bindings[$reviewedManifestPath].sha256;serializationExpectedCount=$summary.expectedCaseCount;serializationActualCount=$summary.actualCaseCount;serializationGroup=$summary.group;serializationTriples=$summary.selectedTriples;publishedFileCount=$publishedCount;inputFileIdentity=$inputEntries[0].identity;engine=$PSVersionTable.PSVersion.ToString();restoreSessionId=(Get-Process -Id $PID).SessionId;passed=$true;scope='Selected real backend serialization/provenance and output groups only; C6/UI8/media/both vision remain separate required gates';selectedScenarios=$Scenario}|ConvertTo-Json -Depth 15) 'restore-e2e-completion' 'frame'
'ROO_INDUSTRIES_RESTORE_E2E_GATES_COMPLETE'
