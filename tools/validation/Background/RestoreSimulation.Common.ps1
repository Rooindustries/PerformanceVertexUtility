if(-not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){throw 'Restore simulations need PowerShell 7.5 or later to keep saved JSON dates as text, like Windows PowerShell 5.1.'}
$PSDefaultParameterValues['ConvertFrom-Json:DateKind']='String'
if(-not ('RooIndustriesNativeProcessControl' -as [type])) {
Add-Type @'
using System;
using System.Diagnostics;
public static class RooIndustriesNativeProcessControl {
 public static IntPtr OpenProcess(uint access,bool inherit,int processId) {
  try { using (Process.GetProcessById(processId)) { return new IntPtr(processId); } }
  catch (ArgumentException) { return IntPtr.Zero; }
 }
 public static bool GetProcessTimes(IntPtr process,out long created,out long exited,out long kernel,out long user) {
  created=0;exited=0;kernel=0;user=0;
  try { using (Process observed=Process.GetProcessById(process.ToInt32())) { created=observed.StartTime.ToUniversalTime().ToFileTimeUtc(); } }
  catch (ArgumentException) { return false; }
  return true;
 }
 public static bool CloseHandle(IntPtr handle) { return handle!=IntPtr.Zero; }
}
public static class RooIndustriesRestoreFixture {
 public static bool InstanceLeaseFree(string name) {
  bool held=false;
  System.Threading.Thread probe=new System.Threading.Thread(() => {
   using (System.Threading.Mutex mutex=new System.Threading.Mutex(false,name)) {
    try { held=mutex.WaitOne(0); } catch (System.Threading.AbandonedMutexException) { held=true; }
    if (held) { mutex.ReleaseMutex(); }
   }
  });
  probe.Start();probe.Join();
  return held;
 }
}
'@
}
function New-FixtureGovernorGate {
 $gate=[Threading.Mutex]::new($true)
 Add-Member -InputObject $gate -Force -MemberType ScriptMethod -Name ReleaseMutex -Value {[void][Threading.Mutex].GetMethod('ReleaseMutex').Invoke($this,$null);$script:Released++;$script:Held=$false}
 Add-Member -InputObject $gate -Force -MemberType ScriptMethod -Name Dispose -Value {[void][Threading.Mutex].GetMethod('Dispose',[Type[]]@()).Invoke($this,$null);$script:Disposed++}
 return $gate
}
function Start-FixtureProbe([string]$Directory,[string]$Name) {
 $path=Join-Path $Directory $Name
 [IO.File]::Copy('/bin/sleep',$path,$true)
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$path;$start.Arguments='1200';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 return [Diagnostics.Process]::Start($start)
}
function New-FixtureSnapshot([Diagnostics.Process]$Process,[hashtable]$Fields) {
 $Fields.processId=$Process.Id;$Fields.processName=$Process.ProcessName;$Fields.processStartTimeUtc=$Process.StartTime.ToUniversalTime().ToString('o');$Fields.executablePath=$Process.MainModule.FileName
 return [pscustomobject]$Fields
}
function Stop-FixtureProbe([Diagnostics.Process]$Probe) {
 $id=$Probe.Id
 try {if(-not$Probe.HasExited){$Probe.Kill();[void]$Probe.WaitForExit(10000)}} catch {}
 try {return @{processId=$id;exited=$Probe.HasExited}} finally {$Probe.Dispose()}
}
