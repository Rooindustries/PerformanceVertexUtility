param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidateSet('start','stop')][string]$Action)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('trace-load-'+$Action) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('trace-load-'+$Action)
$status='fail'
try{
 if($Action -eq 'start'){
  $image=Join-Path $directory 'RooTraceCpuLoad.exe'
  Add-Type -OutputType ConsoleApplication -OutputAssembly (Get-HarnessLongPath $image) @'
using System;
using System.Threading;
public static class RooTraceCpuLoad { public static void Main(){for(int i=1;i<Environment.ProcessorCount;i++)new Thread(Busy){IsBackground=true}.Start();Busy();}static void Busy(){double x=1;while(true){x=Math.Sqrt(x+1.234567);}} }
'@
  Register-HarnessFile $image 'trace-load'|Out-Null
  $load=Start-OwnedProcess -FilePath $image -Purpose trace-load -Lifetime run
  Write-HarnessResult $directory 'load.json' @{identity=$load.Identity;cores=[Environment]::ProcessorCount}|Out-Null
 }else{
  $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.purpose -eq 'trace-load' -and $_.state -eq 'active'})
  if($entries.Count -ne 1){throw 'Expected exactly one owned load process'}
  Remove-HarnessEntry $entries[0]
  Write-HarnessResult $directory 'load-stopped.json' @{identity=$entries[0].identity;stopped=$true}|Out-Null
 }
 $status='pass'
}finally{$status=Complete-HarnessInvocation $status -Cleanup}
