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
using System.Runtime.InteropServices;
public static class RooTraceCpuLoad {
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
 [DllImport("kernel32.dll",SetLastError=true)] static extern UIntPtr SetThreadAffinityMask(IntPtr thread,UIntPtr mask);
 public static void Main(string[] args){new Thread(()=>{Thread.Sleep(240000);Environment.Exit(0);}){IsBackground=true}.Start();int cores=int.Parse(args[0]);for(int i=0;i<cores-1;i++){int cpu=i;new Thread(()=>Busy(cpu)){IsBackground=true}.Start();}Busy(cores-1);}
 static void Busy(int cpu){if(SetThreadAffinityMask(GetCurrentThread(),new UIntPtr(1UL<<cpu))==UIntPtr.Zero)Environment.Exit(2);double x=1;while(true){x=Math.Sqrt(x+1.234567);}}
}
'@
  Register-HarnessFile $image 'trace-load'|Out-Null
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooTraceLoadPlacement {
 [StructLayout(LayoutKind.Sequential)] public struct Power { public uint Version,ControlMask,StateMask; }
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process,uint[] ids,uint count,out uint required);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetProcessDefaultCpuSets(IntPtr process,IntPtr ids,uint count);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessInformation(IntPtr process,int info,ref Power value,uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetProcessInformation(IntPtr process,int info,ref Power value,uint size);
 public static uint[] CpuSets(IntPtr process){uint count;GetProcessDefaultCpuSets(process,null,0,out count);var ids=new uint[count];if(count>0&&!GetProcessDefaultCpuSets(process,ids,count,out count))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());return ids;}
 public static Power ReadPower(IntPtr process){var p=new Power{Version=1};if(!GetProcessInformation(process,4,ref p,12))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());return p;}
 public static void Configure(IntPtr process){if(!SetProcessDefaultCpuSets(process,IntPtr.Zero,0))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());var p=new Power{Version=1,ControlMask=1,StateMask=0};if(!SetProcessInformation(process,4,ref p,12))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());}
}
'@
  $cores=[Environment]::ProcessorCount
  if($cores -gt 63){throw 'The all-core load fixture requires one processor group.'}
  $load=Start-OwnedProcess -FilePath $image -ArgumentList $cores.ToString() -Purpose trace-load -Lifetime run
  $before=$load.process.ProcessorAffinity.ToInt64();$setsBefore=[RooTraceLoadPlacement]::CpuSets($load.handle);$powerBefore=[RooTraceLoadPlacement]::ReadPower($load.handle);$priorityBefore=[string]$load.process.PriorityClass
  [RooTraceLoadPlacement]::Configure($load.handle);$load.process.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
  $mask=([long]1 -shl $cores)-1
  $load.process.ProcessorAffinity=[IntPtr]::new($mask)
  $after=$load.process.ProcessorAffinity.ToInt64()
  if($after -ne $mask){throw 'The CPU load did not receive the full processor mask.'}
  Write-HarnessResult $directory 'load.json' @{identity=$load.Identity;cores=$cores;beforeMask=$before;mask=$after;threads=$cores;cpuSetsBefore=$setsBefore;cpuSetsAfter=[RooTraceLoadPlacement]::CpuSets($load.handle);powerBefore=$powerBefore;powerAfter=[RooTraceLoadPlacement]::ReadPower($load.handle);priorityBefore=$priorityBefore;priorityAfter=[string]$load.process.PriorityClass}|Out-Null
 }else{
  $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.purpose -eq 'trace-load' -and $_.state -eq 'active'})
  if($entries.Count -ne 1){throw 'Expected exactly one owned load process'}
  Remove-HarnessEntry $entries[0]
  Write-HarnessResult $directory 'load-stopped.json' @{identity=$entries[0].identity;stopped=$true}|Out-Null
 }
 $status='pass'
}finally{$status=Complete-HarnessInvocation $status -Cleanup}
