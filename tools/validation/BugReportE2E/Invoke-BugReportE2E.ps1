param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ExpectedCommit,[ValidateSet('All','AppLog','Rendered')][string]$Scenario='All',[switch]$ReaderAdverse)
$ErrorActionPreference='Stop'
$context=$global:RooIndustriesVerificationInvocationContext
if(-not$context -or $context.protocol -cne 'roo-industries-verification-invocation/v2' -or -not$context.frame){throw 'Original windows_ssh interactive-frame protocol-v2 context required.'}
if($Source -ine $context.frame.stagingPath -or $ExpectedCommit -cne $context.frame.sourceCommit){throw 'Source/expected commit differs from original invocation.'}
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$null=Initialize-HarnessInvocation 'Invoke-BugReportE2E' $OutRoot
. (Join-Path $PSScriptRoot 'phases\Phase.Common.ps1')
$script:RooIndustriesScenario=$Scenario
$script:RooIndustriesReaderAdverseRequested=[bool]$ReaderAdverse
$script:RooIndustriesReaderContext=$null
$script:RooIndustriesReaderHolders=New-Object System.Collections.Generic.List[object]
$script:RooIndustriesReaderLeaves=New-Object System.Collections.Generic.List[string]
$script:RooIndustriesReaderProofs=New-Object System.Collections.Generic.List[object]
$errors=New-Object System.Collections.Generic.List[string]
$created=New-Object System.Collections.Generic.List[string]
$phases=New-Object System.Collections.Generic.List[object]
$validOutput=$false;$passed=$false;$cleanup='unrun';$clock=[Diagnostics.Stopwatch]::StartNew()
$selected=@{AppLog=($Scenario -in @('All','AppLog'));Rendered=($Scenario -in @('All','Rendered'))}
function Invoke-RooIndustriesEntryPhase([string]$Name,[scriptblock]$Action){
 $start=[DateTime]::UtcNow.ToString('o');$watch=[Diagnostics.Stopwatch]::StartNew()
 Write-HarnessResult $OutRoot ($Name+'-entry.json') @{phase=$Name;utc=$start;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$script:Harness.FrameId;invocationNonce=$script:Harness.Nonce}|Out-Null
 [Console]::Out.WriteLine('ROO_INDUSTRIES_BUG_REPORT_PHASE_ENTRY '+$Name+' '+$script:RooIndustriesCommit);[Console]::Out.Flush()
 try{
  & $Action
  $item=@{phase=$Name;status='pass';startedUtc=$start;completedUtc=[DateTime]::UtcNow.ToString('o');elapsedMs=$watch.ElapsedMilliseconds}
  $phases.Add($item);Write-HarnessResult $OutRoot ($Name+'-completion.json') $item|Out-Null
  [Console]::Out.WriteLine('ROO_INDUSTRIES_BUG_REPORT_PHASE_COMPLETE '+$Name+' '+$script:RooIndustriesCommit);[Console]::Out.Flush()
 }catch{
  $item=@{phase=$Name;status='fail';startedUtc=$start;failedUtc=[DateTime]::UtcNow.ToString('o');elapsedMs=$watch.ElapsedMilliseconds;error=$_.Exception.ToString();stack=$_.ScriptStackTrace}
  $phases.Add($item);Write-HarnessResult $OutRoot ($Name+'-failure.json') $item|Out-Null
  throw
 }
}
try{
 Assert-RooIndustries ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and [IntPtr]::Size -eq 8) 'Windows PowerShell 5.1 x64 required.'
 Assert-HarnessHostLease
 Assert-RooIndustries ($context.frame.runRoot -ieq $script:Harness.Root -and $context.frame.frameId -ceq $script:Harness.FrameId -and $context.nonce -ceq $script:Harness.Nonce -and $context.frame.manifestSha256 -ceq $script:Harness.Manifest) 'Original Harness differs from supplied context.'
 $manifestPath=Join-Path $Source 'source-verification.json'
 Assert-RooIndustries ((Get-RooIndustriesFileSha256 $manifestPath) -ceq (ConvertTo-RooIndustriesSha256 $script:Harness.Manifest)) 'Original manifest hash differs before source binding.'
 $initial=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
 Assert-RooIndustries ($initial.commit -ceq $ExpectedCommit -and $initial.frameId -ceq $context.frame.frameId -and $initial.machine -ceq $context.frame.machine -and $env:COMPUTERNAME -ieq $initial.machine) 'Expected source/frame/machine differs from original manifest.'
 $script:RooIndustriesCommit=$ExpectedCommit
 $manifest=Assert-RooIndustriesSource $Source
 Assert-RooIndustries ((Get-HarnessPlainPath $OutRoot) -ieq (Join-Path $script:Harness.Root 'report-e2e-results')) 'Only original frame/report-e2e-results is allowed.'
 $null=Assert-RooIndustriesOwnedDirectory $OutRoot
 Assert-RooIndustries (@(Get-HarnessTree $OutRoot).Count -eq 0) 'Preclaimed result directory must be empty.'
 $validOutput=$true
 $fixture=Join-Path $Source 'tools\validation\BugReportE2E'
 Assert-RooIndustries ((Get-HarnessPlainPath $PSScriptRoot) -ieq $fixture) 'Entrypoint is not the verified tracked fixture.'
 $build=Join-Path $script:Harness.Root 'build';$null=New-HarnessDirectory $build 'report-e2e-build' 'frame';$created.Add($build)
 $binding=Enter-RooIndustriesPhase $Source $fixture $build $OutRoot
 if($selected.Rendered){
  $data=Join-Path $script:Harness.Root 'ui-data';$ui=Join-Path $script:Harness.Root 'ui-output';$capture=Join-Path $script:Harness.Root 'capture'
  foreach($path in @($data,$ui,$capture)){$null=New-HarnessDirectory $path 'report-e2e-ui' 'frame';$created.Add($path)}
 }
 Invoke-RooIndustriesEntryPhase 'build' {. (Join-Path $fixture 'phases\Build-Fixtures.ps1') $Source $fixture $build $OutRoot}
 if($selected.AppLog){Invoke-RooIndustriesEntryPhase 'applog' {
  if($ReaderAdverse){$script:RooIndustriesReaderContext=Start-RooIndustriesReaderHolder 'applog' $Source $fixture $build $OutRoot}
  . (Join-Path $fixture 'phases\Run-AppLogDisk.ps1') $Source $fixture $build $OutRoot
  if($ReaderAdverse){Assert-RooIndustries ($script:RooIndustriesReaderContext.Consumed -and $null -ne $script:RooIndustriesReaderContext.Proof) 'Selected AppLog reader proof was not consumed.';$script:RooIndustriesReaderProofs.Add($script:RooIndustriesReaderContext.Proof);$script:RooIndustriesReaderContext=$null}
 }}
 if($selected.Rendered){Invoke-RooIndustriesEntryPhase 'rendered' {
  if($ReaderAdverse){$script:RooIndustriesReaderContext=Start-RooIndustriesReaderHolder 'rendered' $Source $fixture $build $OutRoot}
  . (Join-Path $fixture 'phases\Run-RenderedBugReport.ps1') $Source $fixture $build $OutRoot $data $ui $capture
  if($ReaderAdverse){Assert-RooIndustries ($script:RooIndustriesReaderContext.Consumed -and $null -ne $script:RooIndustriesReaderContext.Proof) 'Selected rendered reader proof was not consumed.';$script:RooIndustriesReaderProofs.Add($script:RooIndustriesReaderContext.Proof);$script:RooIndustriesReaderContext=$null}
 }}
 if($ReaderAdverse){Assert-RooIndustries ($script:RooIndustriesReaderProofs.Count -eq @($selected.Values|Where-Object {$_}).Count -and @($script:RooIndustriesReaderProofs|ForEach-Object {$_['kind']}|Select-Object -Unique).Count -eq $script:RooIndustriesReaderProofs.Count) 'Exactly one actual reader proof per selected phase is required.'}

 $passed=$true
}catch{$errors.Add($_.Exception.ToString());$passed=$false}
finally{
 foreach($holder in @($script:RooIndustriesReaderHolders.ToArray())){
  try{
   if(-not$holder.process.HasExited){Assert-RooIndustries ([RooIndustriesValidationOwnership.Native]::Created($holder.handle).ToString() -ceq $holder.Identity.creationTimeFileTimeUtc -and [RooIndustriesValidationOwnership.Native]::Image($holder.handle) -ceq $holder.Identity.imagePath) 'Original reader holder cleanup identity differs.';Stop-OwnedProcess $holder}
   Assert-RooIndustries ($holder.process.WaitForExit(5000)) 'Original reader holder remained after cleanup.'
   Set-HarnessEntryState $holder.LedgerId 'absent'
  }catch{$errors.Add($_.Exception.ToString())}
 }
 foreach($leaf in @($script:RooIndustriesReaderLeaves.ToArray())){try{$null=Register-RooIndustriesTree $leaf 'report-e2e-retained-reader-evidence'}catch{$errors.Add($_.Exception.ToString())}}
 foreach($path in @($created.ToArray())){try{$null=Register-RooIndustriesTree $path 'report-e2e-retained-output'}catch{$errors.Add($_.Exception.ToString())}}
 try{$null=Assert-RooIndustriesSource $Source;Assert-HarnessHostLease}catch{$errors.Add($_.Exception.ToString())}
 try{$cleanup=Complete-HarnessInvocation $(if($passed -and $errors.Count -eq 0){'pass'}else{'fail'}) -Cleanup;if($cleanup -cne 'pass'){$errors.Add('Invocation cleanup/status failed.')}}catch{$cleanup='fail';$errors.Add($_.Exception.ToString())}
 try{$null=Assert-RooIndustriesSource $Source;Assert-HarnessHostLease}catch{
  $errors.Add($_.Exception.ToString());$cleanup='fail'
  try{$null=Complete-HarnessInvocation 'fail' -Cleanup}catch{$errors.Add($_.Exception.ToString())}
 }
 $passed=$passed -and $errors.Count -eq 0 -and $cleanup -ceq 'pass'
 if($validOutput){
  try{
  $proofs=@{}
  if($passed -and $selected.AppLog){$proofs.AppLog=Read-HarnessLatestResult 'applog-proof.json' -Nonce $script:Harness.Nonce}
  if($passed -and $selected.Rendered){$proofs.Rendered=Read-HarnessLatestResult 'rendered-proof.json' -Nonce $script:Harness.Nonce}
  Write-HarnessResult $OutRoot 'report-e2e-final.json' @{schemaVersion=1;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);requestedScenario=$Scenario;selected=$selected;phases=@($phases.ToArray());proofs=$proofs;uiNonce=$script:Harness.FrameId;invocationNonce=$script:Harness.Nonce;invocationCleanup=$cleanup;passed=$passed;errors=@($errors.ToArray());elapsedMs=$clock.ElapsedMilliseconds;utc=[DateTime]::UtcNow.ToString('o');native=$true;productionStartupProved=$false;readerAdverseRequested=[bool]$ReaderAdverse;readerProofs=@($script:RooIndustriesReaderProofs.ToArray());normalStreamCompletionProved=(-not$ReaderAdverse -and $passed);readerAdverseProof=$(if($ReaderAdverse -and $passed){'Actual duplicated-writer release observed; inherited launch not proved'}else{'unrun or failed'});readerHolderHelperBuildSelected=($ReaderAdverse -and $Scenario -ceq 'Rendered');wholeWindowReleased=$false}|Out-Null
  }catch{
   $errors.Add($_.Exception.ToString());$passed=$false;$cleanup='fail'
   try{$null=Complete-HarnessInvocation 'fail' -Cleanup}catch{$errors.Add($_.Exception.ToString())}
  }
 }
}
if(-not$passed){throw ('Report E2E failed; retain original frame evidence. '+($errors -join '; '))}
$marker=if($ReaderAdverse){'ROO_INDUSTRIES_BUG_REPORT_READER_ADVERSE_COMPLETE'}else{'ROO_INDUSTRIES_BUG_REPORT_E2E_COMPLETE'}
[Console]::Out.WriteLine($marker+' '+$Scenario+' '+$script:RooIndustriesCommit+' '+(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest));[Console]::Out.Flush()
