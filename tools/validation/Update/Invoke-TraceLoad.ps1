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
  New-HarnessConsoleAssembly -Path $image -Code @'
using System;
using System.Threading;
public static class RooTraceCpuLoad { public static void Main(string[] args){int cores=int.Parse(args[0]);for(int i=1;i<cores;i++)new Thread(Busy){IsBackground=true}.Start();Busy();}static void Busy(){double x=1;while(true){x=Math.Sqrt(x+1.234567);}} }
'@
  Register-HarnessFile $image 'trace-load'|Out-Null
  $cores=[Environment]::ProcessorCount
  if($cores -gt 63){throw 'The all-core load fixture requires one processor group.'}
  $load=Start-OwnedProcess -FilePath $image -ArgumentList $cores.ToString() -Purpose trace-load -Lifetime run
  $before=$load.process.ProcessorAffinity.ToInt64()
  $mask=([long]1 -shl $cores)-1
  $load.process.ProcessorAffinity=[IntPtr]::new($mask)
  $after=$load.process.ProcessorAffinity.ToInt64()
  if($after -ne $mask){throw 'The CPU load did not receive the full processor mask.'}
  Write-HarnessResult $directory 'load.json' @{identity=$load.Identity;cores=$cores;beforeMask=$before;mask=$after;threads=$cores}|Out-Null
 }else{
  $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.purpose -eq 'trace-load' -and $_.state -eq 'active'})
  if($entries.Count -ne 1){throw 'Expected exactly one owned load process'}
  Remove-HarnessEntry $entries[0]
  Write-HarnessResult $directory 'load-stopped.json' @{identity=$entries[0].identity;stopped=$true}|Out-Null
 }
 $status='pass'
}finally{$status=Complete-HarnessInvocation $status -Cleanup}
