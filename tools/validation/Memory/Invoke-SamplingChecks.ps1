param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Memory\Memory.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'memory-sampling-checks' $OutRoot
Assert-HarnessHostLease;Ensure-HarnessOutputDirectory $OutRoot
$install=Join-Path $OutRoot 'fixtures';New-HarnessDirectory $install 'sampler-fixtures'|Out-Null
$appPath=Join-Path $install 'RooMemoryApp.exe';$helperPath=Join-Path $install 'RooMemoryHelper.exe'
Copy-HarnessFile (Join-Path $env:SystemRoot 'System32\PING.EXE') $appPath|Out-Null
Copy-HarnessFile (Join-Path $env:SystemRoot 'System32\PING.EXE') $helperPath|Out-Null
$script:receipt=Start-OwnedProcess -FilePath (Get-HarnessToolPath $appPath) -ArgumentList '-t 127.0.0.1' -Purpose sampler-app -WindowStyle Hidden
$script:app=$script:receipt.process
$helperReceipt=Start-OwnedProcess -FilePath (Get-HarnessToolPath $helperPath) -ArgumentList '-t 127.0.0.1' -Purpose sampler-helper -WindowStyle Hidden
$script:helperId=$helperReceipt.Identity.pid;$script:stoppedForSample=$false
$script:rows=[Collections.Generic.List[object]]::new();$script:samples=[Collections.Generic.List[object]]::new();$script:samplingRaces=[Collections.Generic.List[object]]::new();$script:ownedHelpers=[Collections.Generic.List[object]]::new();$script:helpersSeen=[Collections.Generic.HashSet[string]]::new();$script:runClock=[Diagnostics.Stopwatch]::StartNew()
function Log([string]$Text){}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'tools\validation\Memory\Measure-Memory.ps1'))),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Measurement script does not parse'}
foreach($name in 'Processes','Sample'){$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true);if(-not$function){throw 'Real sampler function missing'};Invoke-Expression $function.Extent.Text}
function Get-Process([int]$Id){
 if($Id -eq $script:helperId -and -not$script:stoppedForSample){$script:stoppedForSample=$true;Stop-HarnessProcess $helperReceipt}
 Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
}
try{
 Start-Sleep 2
 Sample 1 'fixture-helper-exit' 0 'minimized'
 $recorded=@($script:samplingRaces|Where-Object pid -EQ $script:helperId)
 if($recorded.Count -ne 1 -or @($script:rows|Where-Object pid -EQ $script:helperId).Count -or @($script:rows|Where-Object kind -EQ 'app').Count -ne 1){throw 'Exited helper was lost, invented or aborted the real sample'}
 Stop-HarnessProcess $script:receipt
 $refused=$false;try{Sample 1 'fixture-app-exit' 0 'minimized'}catch{if($_.Exception.Message -like '*Measured app exited before sampling*'){$refused=$true}else{throw}}
 if(-not$refused){throw 'Exited app was silently omitted'}
 Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';checks=@(@{name='helper exits between enumeration and process read';passed=$true;race=$recorded[0];rows=@($script:rows)},@{name='exited app refuses sample';passed=$true})}|Out-Null
}finally{Stop-HarnessProcess $helperReceipt;Stop-HarnessProcess $script:receipt}
