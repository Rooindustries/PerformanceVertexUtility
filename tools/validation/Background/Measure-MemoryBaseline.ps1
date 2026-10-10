param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string]$Analyzer='',[switch]$FocusSamples)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Roo20MemoryNative {
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int mode);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("kernel32.dll")] public static extern bool SetProcessInformation(IntPtr h,int kind,ref uint value,int size);
 [DllImport("ntdll.dll")] public static extern int NtSetInformationProcess(IntPtr h,int kind,ref int value,int size);
}
'@
[Roo20MemoryNative]::SetProcessDPIAware()|Out-Null
$self=[Diagnostics.Process]::GetCurrentProcess();$self.PriorityClass='Normal';[uint32]$m=5;[int]$io=2
if(-not[Roo20MemoryNative]::SetProcessInformation($self.Handle,0,[ref]$m,4)){throw 'Could not normalize evidence process memory priority'}
if([Roo20MemoryNative]::NtSetInformationProcess($self.Handle,33,[ref]$io,4) -ne 0){throw 'Could not normalize evidence process I/O priority'}
$install='C:\Program Files\Roo Industries\Optimization Suite'
$exe=Join-Path $install 'app\RooIndustries.OptimizationSuite.App.exe'
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
Assert-NoUnownedAppProcess
$script:app=$null;$script:receipt=$null;$script:window=$null
$script:rows=[Collections.Generic.List[object]]::new();$script:samples=[Collections.Generic.List[object]]::new();$script:runClock=$null
$script:ownedHelpers=[Collections.Generic.List[object]]::new();$script:helpersSeen=[Collections.Generic.HashSet[string]]::new()
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $OutRoot $name),($value|ConvertTo-Json -Depth 30),$utf8)}
function Log([string]$text){[IO.File]::AppendAllText((Join-Path $OutRoot 'journey.log'),([DateTime]::UtcNow.ToString('o')+' '+$text+"`r`n"),$utf8)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=& $probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out waiting for '+$what)}
function ById([string]$id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Texts{@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|Where-Object {-not$_.Current.IsOffscreen}|ForEach-Object {[string]$_.Current.Name}|Where-Object {$_})}
function Activate($element){try{$element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){$e=WaitFor {$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 30 ('navigation '+$name);Activate $e;Log ('NAV '+$name)}
function Tab([string]$id){Activate (WaitFor {ById $id} 30 ('tab '+$id));WaitFor {$e=ById $id;$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected} 10 ($id+' selected')|Out-Null;Log ('TAB '+$id)}
function Shot([string]$name){$r=$script:window.Current.BoundingRectangle;if($r.Width -lt 1 -or $r.Height -lt 1){return};$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save((Join-Path $OutRoot ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}}
function Processes{
 $all=@(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate)
 $ids=[Collections.Generic.HashSet[int]]::new();[void]$ids.Add($script:app.Id)
 do{$added=$false;foreach($p in $all){if(($ids.Contains([int]$p.ParentProcessId) -or ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($install+'\',[StringComparison]::OrdinalIgnoreCase))) -and -not$ids.Contains([int]$p.ProcessId)){[void]$ids.Add([int]$p.ProcessId);$added=$true}}}while($added)
 @($all|Where-Object {$ids.Contains([int]$_.ProcessId)})
}
function Sample([int]$run,[string]$point,[int]$settle,[string]$state='active'){
 $utc=[DateTime]::UtcNow.ToString('o');$procs=@(Processes);$perf=@(Get-CimInstance Win32_PerfRawData_PerfProc_Process -Property IDProcess,Name,WorkingSetPrivate,WorkingSet,PrivateBytes)
 $memory=[Collections.Generic.List[object]]::new()
 foreach($c in $procs){
  try{$p=Get-Process -Id $c.ProcessId -ErrorAction Stop;$p.Refresh();if([Math]::Abs(($p.StartTime.ToUniversalTime()-$c.CreationDate.ToUniversalTime()).TotalMilliseconds) -gt 1){throw 'Process identity changed during sample'}
   $counter=@($perf|Where-Object {[int]$_.IDProcess -eq $p.Id});if($counter.Count -ne 1){throw ('Private working-set counter missing for PID '+$p.Id)}
   $row=[pscustomobject]@{run=$run;point=$point;windowState=$state;settleSeconds=$settle;utc=$utc;elapsedSeconds=[Math]::Round($script:runClock.Elapsed.TotalSeconds,3);pid=$p.Id;parentPid=[int]$c.ParentProcessId;image=[string]$c.Name;imagePath=[string]$c.ExecutablePath;kind=$(if($p.Id -eq $script:app.Id){'app'}else{'helper'});workingSetBytes=$p.WorkingSet64;privateBytes=$p.PrivateMemorySize64;privateWorkingSetBytes=[long]$counter[0].WorkingSetPrivate;perfInstance=[string]$counter[0].Name;cpuMilliseconds=$p.TotalProcessorTime.TotalMilliseconds;priorityClass=[string]$p.PriorityClass;startTimeUtc=$p.StartTime.ToUniversalTime().ToString('o')}
   $memory.Add($row);$script:rows.Add($row)
   if($p.Id -ne $script:app.Id){$r=New-OwnedProcess $p;if($r -and $script:helpersSeen.Add($r.Identity.pid.ToString()+':'+$r.Identity.creationTimeFileTimeUtc)){$script:ownedHelpers.Add($r)}}
  }catch{Log ('SAMPLE ERROR '+$c.ProcessId+' '+$_.Exception.Message);throw}
 }
 $total=[pscustomobject]@{run=$run;point=$point;windowState=$state;settleSeconds=$settle;utc=$utc;elapsedSeconds=[Math]::Round($script:runClock.Elapsed.TotalSeconds,3);pid=0;parentPid=0;image='TOTAL';imagePath='';kind='total';workingSetBytes=[long](($memory|Measure-Object workingSetBytes -Sum).Sum);privateBytes=[long](($memory|Measure-Object privateBytes -Sum).Sum);privateWorkingSetBytes=[long](($memory|Measure-Object privateWorkingSetBytes -Sum).Sum);perfInstance='';cpuMilliseconds=($memory|Measure-Object cpuMilliseconds -Sum).Sum;priorityClass='';startTimeUtc=''}
 $script:rows.Add($total)
 $texts=if($state -eq 'active'){@(Texts)}else{@()}
 $script:samples.Add([ordered]@{run=$run;point=$point;utc=$utc;state=$state;settleSeconds=$settle;appPid=$script:app.Id;processes=@($memory);total=$total;visibleText=$texts})
 $script:rows|Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $OutRoot 'memory.csv')
 Save 'memory.json' @($script:samples)
 Save 'owned-processes.json' @{app=$script:receipt.Identity;helpers=@($script:ownedHelpers|ForEach-Object {$_.Identity})}
 if($state -eq 'active'){Shot ('run'+$run+'-'+($point -replace '\W','-'))}
 Log ('SAMPLE run='+$run+' point='+$point+' privateWs='+$total.privateWorkingSetBytes+' privateBytes='+$total.privateBytes+' processes='+$memory.Count)
}
$settings=[Collections.Generic.List[object]]::new()
foreach($folder in @('RooIndustriesOptimizationSuite','RooOptimizationSuite')){$path=Join-Path $env:LOCALAPPDATA ($folder+'\settings.json');if(Test-Path $path){$bytes=[IO.File]::ReadAllBytes($path);$settings.Add(@{path=$path;bytes=$bytes;hash=(Get-FileHash $path).Hash});$j=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json;if($j.simpleMode -eq '0'){$j.simpleMode='1';[IO.File]::WriteAllText($path,($j|ConvertTo-Json -Compress),$utf8)}}}
Save 'settings-as-found.json' @($settings|ForEach-Object {@{path=$_.path;hash=$_.hash;existed=$true}})
Save 'recipe.json' @{machine=$env:COMPUTERNAME;version=(Get-Item $exe).VersionInfo.ProductVersion;build=(Get-CimInstance Win32_OperatingSystem).Version;administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);session=[Diagnostics.Process]::GetCurrentProcess().SessionId;initialHomeSeconds=60;pageSettleSeconds=15;finalHomeSeconds=60;minimizedSeconds=60;sampleProvider='Win32_PerfRawData_PerfProc_Process.WorkingSetPrivate (Process\Working Set - Private) matched by IDProcess';buildProcessExclusion='Only installed Suite image paths and descendants of this app PID; staged build helpers are excluded';normalLaunchPriority='Parent process normalized to Normal CPU, Normal I/O (2), Normal memory (5) before app launch'}
try{
 for($run=1;$run -le 3;$run++){
  $script:runClock=[Diagnostics.Stopwatch]::StartNew();Log ('RUN START '+$run)
  $script:app=Start-Process $exe -PassThru;$script:receipt=New-OwnedProcess $script:app
  Save 'owned-processes.json' @{app=$script:receipt.Identity;helpers=@($script:ownedHelpers|ForEach-Object {$_.Identity})}
  $script:window=WaitFor { $condition=[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id);@($A::RootElement.FindAll($TS::Children,$condition)|Where-Object {$_.Current.Name -like 'Roo Industries*' -and $_.Current.NativeWindowHandle -ne 0})|Select-Object -First 1 } 120 'app main window'
  [Roo20MemoryNative]::SetWindowPos([IntPtr]::new($script:window.Current.NativeWindowHandle),[IntPtr]::new(-1),0,0,0,0,0x43)|Out-Null
  [Roo20MemoryNative]::SetForegroundWindow([IntPtr]::new($script:window.Current.NativeWindowHandle))|Out-Null
  try{$script:window.SetFocus()}catch{}
  WaitFor {(@(Texts) -contains 'Start here')} 120 'Home rendered'|Out-Null
  if($run -eq 1){Save 'app-runtimeconfig.json' (Get-Content -Raw (Join-Path $install 'app\RooIndustries.OptimizationSuite.App.runtimeconfig.json')|ConvertFrom-Json);try{Save 'diagnostic-pipes.json' @{pid=$script:app.Id;matching=@([IO.Directory]::GetFiles('\\.\pipe\')|Where-Object {$_ -like ('*dotnet-diagnostic-'+$script:app.Id+'*')})}}catch{Save 'diagnostic-pipes.json' @{pid=$script:app.Id;error=$_.Exception.Message}}}
  Start-Sleep 60;Sample $run 'initial-Home-60s' 60
  $journey=@(
   @{point='Home';nav='Home'},
   @{point='Games-Games';nav='Games';tab='GamesTab'},
   @{point='Games-Processes';tab='ProcessesTab'},
   @{point='Games-Background-apps';tab='BackgroundTab'},
   @{point='Remove-apps';nav='Remove apps'},
   @{point='Graphics-drivers';nav='Graphics drivers'},
   @{point='Windows-tweaks';nav='Windows tweaks'},
   @{point='Tools';nav='Tools'},
   @{point='Undo-changes';nav='Undo changes'},
   @{point='Report-a-bug';nav='Report a bug'},
   @{point='Settings';nav='Settings'},
   @{point='Home-return';nav='Home'}
  )
  foreach($page in $journey){if($page.nav){Nav $page.nav};if($page.tab){Tab $page.tab};Start-Sleep 15;Sample $run $page.point 15;if($page.point -eq 'Settings'){$toggle=ById 'SimpleModeToggle';if(-not$toggle -or [string]$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne 'On'){throw 'Simple mode is not enabled'}}}
  Start-Sleep 60;Sample $run 'final-Home-60s' 60
  [Roo20MemoryNative]::ShowWindow([IntPtr]::new($script:window.Current.NativeWindowHandle),6)|Out-Null;Log 'MINIMIZE';Start-Sleep 60;Sample $run 'minimized-60s' 60 'minimized'
  if($FocusSamples){
   [Roo20MemoryNative]::ShowWindow([IntPtr]::new($script:window.Current.NativeWindowHandle),9)|Out-Null
   Start-Sleep 3
   $focusWindow=[Windows.Forms.Form]::new();$focusWindow.Text='Roo Industries evidence focus window';$focusWindow.Width=500;$focusWindow.Height=150;$focusWindow.TopMost=$true
   try {
    $focusWindow.Show();$focusWindow.Activate();[Roo20MemoryNative]::SetForegroundWindow($focusWindow.Handle)|Out-Null;[Windows.Forms.Application]::DoEvents();if([Roo20MemoryNative]::GetForegroundWindow() -ne $focusWindow.Handle){throw 'Evidence window did not take focus'};Log 'FOCUS LOST to evidence window'
    Start-Sleep 10;Sample $run 'unfocused-10s' 10 'unfocused'
    Start-Sleep 30;Sample $run 'unfocused-40s' 40 'unfocused'
   } finally {$focusWindow.Close();$focusWindow.Dispose()}
  }
  if($run -eq 3 -and $Analyzer){
   $probe=Start-Process $Analyzer -ArgumentList @($script:app.Id,('"'+(Join-Path $OutRoot 'heap-analysis.json')+'"'),('"'+(Join-Path $install 'app\mscordaccore.dll')+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $OutRoot 'heap-analysis.log') -RedirectStandardError (Join-Path $OutRoot 'heap-analysis-error.log');$probeReceipt=New-OwnedProcess $probe
   try{if(-not$probe.WaitForExit(90000)){throw 'Heap analysis exceeded ninety seconds'};Log ('HEAP ANALYSIS exit='+$probe.ExitCode)}finally{Stop-OwnedProcess $probeReceipt}
  }
  Stop-OwnedValidationApp $script:app $script:receipt;Log ('RUN STOP '+$run);$script:app=$null;$script:receipt=$null;$script:window=$null;Start-Sleep 3
 }
 Save 'done.json' @{status='completed';runs=3;samples=$script:samples.Count;utc=[DateTime]::UtcNow.ToString('o')}
 'Three memory baseline runs completed'
}finally{
 if($script:app){Stop-OwnedValidationApp $script:app $script:receipt}
 foreach($r in $script:ownedHelpers){Stop-OwnedProcess $r}
 foreach($s in $settings){[IO.File]::WriteAllBytes($s.path,$s.bytes);if((Get-FileHash $s.path).Hash -cne $s.hash){throw 'As-found settings bytes were not restored'}}
 Save 'cleanup.json' @{appStopped=(@(Get-Process RooIndustries.OptimizationSuite.App -ErrorAction SilentlyContinue).Count -eq 0);helperProcesses=@($script:ownedHelpers|ForEach-Object {@{identity=$_.Identity;exited=$_.process.HasExited}});settingsRestored=@($settings|ForEach-Object {@{path=$_.path;expectedHash=$_.hash;actualHash=(Get-FileHash $_.path).Hash}})}
}
