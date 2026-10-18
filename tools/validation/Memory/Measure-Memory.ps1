param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string]$Analyzer='',[ValidateRange(1,10)][int]$Runs=3)
$ErrorActionPreference='Stop'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Memory\Memory.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'memory-baseline' $OutRoot
Assert-HarnessHostLease;Ensure-HarnessOutputDirectory $OutRoot
$script:samplingRaces=[Collections.Generic.List[object]]::new();$script:logBindings=[Collections.Generic.List[object]]::new();$script:files=@{};$script:reopenRows=[Collections.Generic.List[object]]::new();$script:extraRows=[Collections.Generic.List[object]]::new();$script:extraSamples=[Collections.Generic.List[object]]::new()

$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1'))
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesMemoryNative {
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int mode);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("kernel32.dll")] public static extern bool SetProcessInformation(IntPtr h,int kind,ref uint value,int size);
 [DllImport("ntdll.dll")] public static extern int NtSetInformationProcess(IntPtr h,int kind,ref int value,int size);
}
'@
[RooIndustriesMemoryNative]::SetProcessDPIAware()|Out-Null
$self=[Diagnostics.Process]::GetCurrentProcess();$self.PriorityClass='Normal';[uint32]$m=5;[int]$io=2
if(-not[RooIndustriesMemoryNative]::SetProcessInformation($self.Handle,0,[ref]$m,4)){throw 'Could not normalize evidence process memory priority'}
if([RooIndustriesMemoryNative]::NtSetInformationProcess($self.Handle,33,[ref]$io,4) -ne 0){throw 'Could not normalize evidence process I/O priority'}
$install='C:\Program Files\Roo Industries\Optimization Suite'
$exe=Join-Path $install 'app\RooIndustries.OptimizationSuite.App.exe'
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$utf8=[Text.UTF8Encoding]::new($false)
Assert-NoForeignInstance $exe
$script:app=$null;$script:receipt=$null;$script:window=$null
$script:rows=[Collections.Generic.List[object]]::new();$script:samples=[Collections.Generic.List[object]]::new();$script:runClock=$null
$script:ownedHelpers=[Collections.Generic.List[object]]::new();$script:helpersSeen=[Collections.Generic.HashSet[string]]::new()
function Save([string]$name,$value){$path=Write-HarnessResult $OutRoot $name $value;$script:files[$name]=@{path=$path;format='json';sha256=Get-HarnessFileSha256 $path}}
function SaveCsv([string]$name,$value){$path=Get-HarnessOutputPath $OutRoot $name;New-HarnessText $path (($value|ConvertTo-Csv -NoTypeInformation)-join "`r`n") 'memory-csv'|Out-Null;$script:files[$name]=@{path=$path;format='csv';sha256=Get-HarnessFileSha256 $path}}
$journeyPath=Get-HarnessOutputPath $OutRoot 'journey.log';$journeyStream=[IO.FileStream]::new((Get-HarnessLongPath $journeyPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$journeyWriter=[IO.StreamWriter]::new($journeyStream,$utf8)
function Log([string]$text){$journeyWriter.WriteLine([DateTime]::UtcNow.ToString('o')+' nonce='+$nonce+' '+$text);$journeyWriter.Flush()}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=& $probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out waiting for '+$what)}
function ById([string]$id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Texts{@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|Where-Object {-not$_.Current.IsOffscreen}|ForEach-Object {[string]$_.Current.Name}|Where-Object {$_})}
function Activate($element){try{$element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Nav([string]$name){$e=WaitFor {$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 30 ('navigation '+$name);Activate $e;Log ('NAV '+$name)}
function Tab([string]$id){Activate (WaitFor {ById $id} 30 ('tab '+$id));WaitFor {$e=ById $id;$e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected} 10 ($id+' selected')|Out-Null;Log ('TAB '+$id)}
function Shot([string]$name){$r=$script:window.Current.BoundingRectangle;if($r.Width -lt 1 -or $r.Height -lt 1){return};$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$path=Get-HarnessOutputPath $OutRoot ($name+'.png');$stream=[IO.FileStream]::new((Get-HarnessLongPath $path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$b.Save($stream,[Drawing.Imaging.ImageFormat]::Png)}finally{$stream.Dispose()};Register-HarnessFile $path 'screenshot'|Out-Null}finally{$g.Dispose();$b.Dispose()}}
function Processes{
 $all=@(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate)
 $ids=[Collections.Generic.HashSet[int]]::new();[void]$ids.Add($script:app.Id)
 do{$added=$false;foreach($p in $all){if(($ids.Contains([int]$p.ParentProcessId) -or ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($install+'\',[StringComparison]::OrdinalIgnoreCase))) -and -not$ids.Contains([int]$p.ProcessId)){[void]$ids.Add([int]$p.ProcessId);$added=$true}}}while($added)
 @($all|Where-Object {$ids.Contains([int]$_.ProcessId)})
}
function Sample([int]$run,[string]$point,[int]$settle,[string]$state='active'){
 if($script:app.HasExited){throw 'Measured app exited before sampling'};$known=Get-HarnessProcess $script:app.Id;if(-not$known -or $known.Identity.creationTimeFileTimeUtc -cne $script:receipt.Identity.creationTimeFileTimeUtc){throw 'Measured app identity changed'}
 $utc=[DateTime]::UtcNow.ToString('o');$procs=@(Processes);$perf=@(Get-CimInstance Win32_PerfRawData_PerfProc_Process -Property IDProcess,Name,WorkingSetPrivate,WorkingSet,PrivateBytes)
 $memory=[Collections.Generic.List[object]]::new()
 foreach($c in $procs){
  $helper=$null;$p=$null
  try{
   try{$p=Get-Process -Id $c.ProcessId -ErrorAction Stop}catch [Microsoft.PowerShell.Commands.ProcessCommandException]{
    if($c.ProcessId -eq $script:app.Id -or @(Get-CimInstance Win32_Process -Filter ('ProcessId='+$c.ProcessId)).Count){throw}
    $script:samplingRaces.Add(@{run=$run;point=$point;pid=[int]$c.ProcessId;image=$c.Name;path=$c.ExecutablePath;creationDate=$c.CreationDate;reason='exited between enumeration and read';utc=[DateTime]::UtcNow.ToString('o')});Log ('HELPER EXITED '+$c.ProcessId+' '+$c.Name);continue
   }
   $helper=$null
   if($p.Id -ne $script:app.Id){$helper=Test-OwnedDescendant $p.Id -PassThru;if(-not$helper){if($p.HasExited){$script:samplingRaces.Add(@{run=$run;point=$point;pid=$p.Id;image=$c.Name;reason='exited before ownership read';utc=[DateTime]::UtcNow.ToString('o')});continue};throw ('Foreign helper PID '+$p.Id+'; retained')};if($script:helpersSeen.Add($helper.Identity.pid.ToString()+':'+$helper.Identity.creationTimeFileTimeUtc)){$script:ownedHelpers.Add($helper)}}
   $p.Refresh();if([Math]::Abs(($p.StartTime.ToUniversalTime()-$c.CreationDate.ToUniversalTime()).TotalMilliseconds) -gt 1){throw 'Process identity changed during sample'}
   $counter=@($perf|Where-Object {[int]$_.IDProcess -eq $p.Id});if($counter.Count -ne 1){throw ('Private working-set counter missing for PID '+$p.Id)}
   $row=[pscustomobject]@{nonce=$nonce;run=$run;point=$point;windowState=$state;settleSeconds=$settle;utc=$utc;elapsedSeconds=[Math]::Round($script:runClock.Elapsed.TotalSeconds,3);pid=$p.Id;parentPid=[int]$c.ParentProcessId;image=[string]$c.Name;imagePath=[string]$c.ExecutablePath;kind=$(if($p.Id -eq $script:app.Id){'app'}else{'helper'});workingSetBytes=$p.WorkingSet64;privateBytes=$p.PrivateMemorySize64;privateWorkingSetBytes=[long]$counter[0].WorkingSetPrivate;perfInstance=[string]$counter[0].Name;cpuMilliseconds=$p.TotalProcessorTime.TotalMilliseconds;priorityClass=[string]$p.PriorityClass;startTimeUtc=$p.StartTime.ToUniversalTime().ToString('o')}
   $memory.Add($row);$script:rows.Add($row)
  }catch{
   if($helper -and $p.HasExited){$script:samplingRaces.Add(@{run=$run;point=$point;pid=$p.Id;image=$c.Name;identity=$helper.Identity;reason='owned helper exited during metrics read';utc=[DateTime]::UtcNow.ToString('o')});continue}
   Log ('SAMPLE ERROR '+$c.ProcessId+' '+$c.Name+' '+$_.Exception.Message);throw
  }
 }
 $total=[pscustomobject]@{nonce=$nonce;run=$run;point=$point;windowState=$state;settleSeconds=$settle;utc=$utc;elapsedSeconds=[Math]::Round($script:runClock.Elapsed.TotalSeconds,3);pid=0;parentPid=0;image='TOTAL';imagePath='';kind='total';workingSetBytes=[long](($memory|Measure-Object workingSetBytes -Sum).Sum);privateBytes=[long](($memory|Measure-Object privateBytes -Sum).Sum);privateWorkingSetBytes=[long](($memory|Measure-Object privateWorkingSetBytes -Sum).Sum);perfInstance='';cpuMilliseconds=($memory|Measure-Object cpuMilliseconds -Sum).Sum;priorityClass='';startTimeUtc=''}
 $script:rows.Add($total)
 $texts=if($state -eq 'active'){@(Texts)}else{@()}
 $script:samples.Add([ordered]@{nonce=$nonce;run=$run;point=$point;utc=$utc;state=$state;settleSeconds=$settle;appPid=$script:app.Id;processes=@($memory);total=$total;visibleText=$texts})
 if($state -ne 'minimized'){Shot ('run'+$run+'-'+($point -replace '\W','-'))}
 Log ('SAMPLE run='+$run+' point='+$point+' privateWs='+$total.privateWorkingSetBytes+' privateBytes='+$total.privateBytes+' processes='+$memory.Count)
}
$settings=[Collections.Generic.List[object]]::new()
foreach($folder in @('RooIndustriesOptimizationSuite','RooOptimizationSuite')){$path=Join-Path $env:LOCALAPPDATA ($folder+'\settings.json');if(Test-HarnessPath $path){$bytes=[IO.File]::ReadAllBytes((Get-HarnessLongPath $path));$settings.Add(@{path=$path;bytes=$bytes;hash=(Get-HarnessFileSha256 $path)});$j=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json;if($j.simpleMode -eq '0'){$j.simpleMode='1';[IO.File]::WriteAllText((Get-HarnessLongPath $path),($j|ConvertTo-Json -Compress),$utf8)}}}
Save 'settings-as-found.json' @($settings|ForEach-Object {@{path=$_.path;hash=$_.hash;existed=$true}})
Save 'recipe.json' @{machine=$env:COMPUTERNAME;version=(Get-HarnessItem $exe).VersionInfo.ProductVersion.TrimEnd(' ');build=(Get-CimInstance Win32_OperatingSystem).Version;administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);session=[Diagnostics.Process]::GetCurrentProcess().SessionId;initialHomeSeconds=60;pageSettleSeconds=15;finalHomeSeconds=60;minimizedSeconds=60;unfocusedSeconds=@(10,40);runs=$Runs;sampleProvider='Win32_PerfRawData_PerfProc_Process.WorkingSetPrivate (Process\Working Set - Private) matched by IDProcess';buildProcessExclusion='Only installed Suite image paths and descendants of this app PID; staged build helpers are excluded';normalLaunchPriority='Parent process normalized to Normal CPU, Normal I/O (2), Normal memory (5) before app launch'}
$logPath=Join-Path (Get-RooIndustriesLocalDataRoot) 'logs\app.log';$status='fail';$errorText='';$completedRuns=0
try{
 for($run=1;$run -le $Runs;$run++){
  $script:runClock=[Diagnostics.Stopwatch]::StartNew();Log ('RUN START '+$run)
  $cursor=Get-ShippedLogCursor $logPath;$launchUtc=[DateTime]::UtcNow;$logCaptured=$false
  Assert-HarnessHostLease;Assert-NoForeignInstance $exe;$script:receipt=Start-OwnedProcess -FilePath (Get-HarnessToolPath $exe) -WindowStyle Normal -Purpose measured-app;$script:app=$script:receipt.process
  $script:window=WaitFor { $condition=[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$script:app.Id);@($A::RootElement.FindAll($TS::Children,$condition)|Where-Object {$_.Current.Name -like 'Roo Industries*' -and $_.Current.NativeWindowHandle -ne 0})|Select-Object -First 1 } 120 'app main window'
  Register-HarnessWindow $script:window|Out-Null;WaitFor {(@(Texts) -contains 'Start here')} 120 'Home rendered'|Out-Null
  if($run -eq 1){Save 'app-runtimeconfig.json' ([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $install 'app\RooIndustries.OptimizationSuite.App.runtimeconfig.json')))|ConvertFrom-Json);try{Save 'diagnostic-pipes.json' @{pid=$script:app.Id;matching=@([IO.Directory]::GetFiles('\\.\pipe\')|Where-Object {$_ -like ('*dotnet-diagnostic-'+$script:app.Id+'*')})}}catch{Save 'diagnostic-pipes.json' @{pid=$script:app.Id;error=$_.Exception.Message}}}
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
  if($run -eq $Runs -and $Analyzer){
   $heapStart=[DateTime]::UtcNow;Log 'HEAP START final-Home-60s'
   $heapPath=Get-HarnessOutputPath $OutRoot 'heap-analysis.json'
   $analysis=Invoke-HarnessProcess (Get-HarnessToolPath $Analyzer) ($script:app.Id.ToString()+' "'+(Get-HarnessToolPath $heapPath)+'" "'+(Get-HarnessToolPath (Join-Path $install 'app\mscordaccore.dll'))+'"') 'heap-analysis'
   Register-HarnessFile $heapPath 'heap-analysis'|Out-Null;$heap=[IO.File]::ReadAllText((Get-HarnessLongPath $heapPath))|ConvertFrom-Json;if($heap.nonce -cne $nonce -or $heap.pid -ne $script:app.Id){throw 'Heap output identity differs'};$script:files['heap-analysis.json']=@{path=$heapPath;format='bound-json';sha256=Get-HarnessFileSha256 $heapPath}
   Save 'heap-placement.json' @{run=$run;point='final-Home-60s';pid=$script:app.Id;beforeUtc=$heapStart.ToString('o');afterUtc=[DateTime]::UtcNow.ToString('o');stdout=$analysis}
   Log 'HEAP END'
  }
  foreach($page in @('Windows tweaks','Tools','Remove apps')){
   for($repeat=1;$repeat -le 3;$repeat++){
    Nav 'Home';WaitFor {@(Texts) -contains 'Start here'} 30 'Home before reopen'|Out-Null
    $nav=WaitFor {$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$page),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 30 ('reopen navigation '+$page)
    $selection=$nav.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    $startUtc=[DateTime]::UtcNow;$watch=[Diagnostics.Stopwatch]::StartNew();$selection.Select();$selectReturned=$watch.Elapsed.TotalMilliseconds
    $marker=$null
    while($watch.Elapsed.TotalSeconds -lt 120){
     if($page -eq 'Tools'){$marker=ById 'OpenFirmware';if($marker -and ($marker.Current.IsOffscreen -or -not$marker.Current.IsEnabled)){$marker=$null}}
     else{$id=if($page -eq 'Windows tweaks'){'WindowsTweaksList'}else{'RemovalApps'};$list=ById $id;if($list){$marker=@($list.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {-not$_.Current.IsOffscreen})|Select-Object -First 1}}
     if($marker){break};Start-Sleep -Milliseconds 20
    }
    $watch.Stop();if(-not$marker){throw ('Reopen content timeout '+$page)}
    $script:reopenRows.Add([pscustomobject]@{nonce=$nonce;run=$run;page=$page;repeat=$repeat;pid=$script:app.Id;startUtc=$startUtc.ToString('o');contentUtc=[DateTime]::UtcNow.ToString('o');milliseconds=$watch.Elapsed.TotalMilliseconds;markerId=$marker.Current.AutomationId;markerName=$marker.Current.Name;markerType=$marker.Current.ControlType.ProgrammaticName;pollMilliseconds=20;selectionReturnedMilliseconds=$selectReturned;navigationOperation='SelectionItemPattern.Select';heapProbeBeforeSeries=($run -eq $Runs -and [bool]$Analyzer)})
    Shot ('run'+$run+'-reopen-'+($page -replace '\W','-')+'-'+$repeat)
    Log ('REOPEN run='+$run+' page='+$page+' repeat='+$repeat+' ms='+$watch.Elapsed.TotalMilliseconds)
    Nav 'Home';WaitFor {@(Texts) -contains 'Start here'} 30 'Home after reopen'|Out-Null
   }
  }
  Start-Sleep 15
  $beforeRows=$script:rows.Count;$beforeSamples=$script:samples.Count
  Sample $run 'post-reopen-Home-15s' 15
  for($i=$beforeRows;$i -lt $script:rows.Count;$i++){$script:extraRows.Add($script:rows[$i])}
  $script:extraSamples.Add($script:samples[$beforeSamples]);$script:rows.RemoveRange($beforeRows,$script:rows.Count-$beforeRows);$script:samples.RemoveAt($beforeSamples)
  [RooIndustriesMemoryNative]::ShowWindow([IntPtr]::new($script:window.Current.NativeWindowHandle),6)|Out-Null;Log 'MINIMIZE';Start-Sleep 60;Sample $run 'minimized-60s' 60 'minimized'
  [RooIndustriesMemoryNative]::ShowWindow([IntPtr]::new($script:window.Current.NativeWindowHandle),9)|Out-Null;Start-Sleep 3
  $focusWindow=[Windows.Forms.Form]::new();$focusWindow.Text='Roo Industries evidence focus window';$focusWindow.Width=500;$focusWindow.Height=150;$focusWindow.TopMost=$true
  try{
   Assert-HarnessHostLease;$focusWindow.Show();$focusWindow.Activate();[RooIndustriesMemoryNative]::SetForegroundWindow($focusWindow.Handle)|Out-Null;[Windows.Forms.Application]::DoEvents()
   Register-HarnessWindow ($A::FromHandle($focusWindow.Handle))|Out-Null
   if([RooIndustriesMemoryNative]::GetForegroundWindow() -ne $focusWindow.Handle){throw 'Evidence window did not take focus'};Log 'FOCUS LOST to owned evidence window'
   Start-Sleep 10;Sample $run 'unfocused-10s' 10 'unfocused';Start-Sleep 30;Sample $run 'unfocused-40s' 40 'unfocused'
  }finally{$focusWindow.Close();$focusWindow.Dispose()}
  Stop-OwnedValidationApp $script:app $script:receipt;Stop-HarnessProcess $script:receipt;Log ('RUN STOP '+$run)
  $segment=Read-ShippedLog $cursor;$path=Get-HarnessOutputPath $OutRoot ('app-log-run'+$run+'.txt');New-HarnessText $path $segment 'app-log'|Out-Null;$script:files['app-log-run'+$run+'.txt']=@{path=$path;format='text';sha256=Get-HarnessFileSha256 $path}
  $logCaptured=$true;$script:logBindings.Add(@{run=$run;identity=$script:receipt.Identity;launchUtc=$launchUtc.ToString('o');endUtc=[DateTime]::UtcNow.ToString('o');logPath=$logPath;cursorLength=$cursor.length})
  if($segment.Contains('Freeing memory failed')){throw 'The app logged Freeing memory failed'}
  $completedRuns++;$script:app=$null;$script:receipt=$null;$script:window=$null;Start-Sleep 3
 }
 $status='pass'
}catch{$errorText=$_.Exception.ToString();throw}finally{
 try{
  if($script:app){
   Stop-OwnedValidationApp $script:app $script:receipt;Stop-HarnessProcess $script:receipt
   if(-not$logCaptured){$segment=Read-ShippedLog $cursor;$path=Get-HarnessOutputPath $OutRoot ('app-log-run'+$run+'.txt');New-HarnessText $path $segment 'app-log'|Out-Null;$script:files['app-log-run'+$run+'.txt']=@{path=$path;format='text';sha256=Get-HarnessFileSha256 $path};$script:logBindings.Add(@{run=$run;identity=$script:receipt.Identity;launchUtc=$launchUtc.ToString('o');endUtc=[DateTime]::UtcNow.ToString('o');logPath=$logPath;cursorLength=$cursor.length;partial=$true})}
  }
  foreach($receipt in $script:ownedHelpers){Stop-HarnessProcess $receipt}
  foreach($setting in $settings){[IO.File]::WriteAllBytes((Get-HarnessLongPath $setting.path),$setting.bytes);if((Get-HarnessFileSha256 $setting.path) -cne $setting.hash){throw 'As-found settings bytes were not restored'}}
  SaveCsv 'memory.csv' @($script:rows);Save 'memory.json' @($script:samples)
  SaveCsv 'post-reopen-memory.csv' @($script:extraRows);Save 'post-reopen-memory.json' @($script:extraSamples)
  SaveCsv 'reopen.csv' @($script:reopenRows);Save 'reopen.json' @($script:reopenRows)
  Save 'sampling-races.json' @($script:samplingRaces)
  Save 'app-log-bindings.json' @($script:logBindings)
  Save 'cleanup.json' @{appStopped=(-not$script:app -or $script:app.HasExited);helperProcesses=@($script:ownedHelpers|ForEach-Object {@{identity=$_.Identity;exited=$_.process.HasExited}});settingsRestored=@($settings|ForEach-Object {@{path=$_.path;expectedHash=$_.hash;actualHash=Get-HarnessFileSha256 $_.path}})}
 }catch{$status='fail';$errorText+="`nCleanup: "+$_.Exception.ToString();throw}finally{
  $journeyWriter.Dispose();$journeyStream.Dispose();Register-HarnessFile $journeyPath 'journey'|Out-Null;$script:files['journey.log']=@{path=$journeyPath;format='text';sha256=Get-HarnessFileSha256 $journeyPath}
  Write-HarnessResult $OutRoot 'receipt.json' @{status=$status;error=$errorText;requestedRuns=$Runs;completedRuns=$completedRuns;samples=$script:samples.Count;reopens=$script:reopenRows.Count;files=$script:files}|Out-Null
 }
}
