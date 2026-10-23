param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$ProcessExplorer,[ValidateRange(45,300)][int]$InspectSeconds=90)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'high-io-inspect' $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
foreach($folder in 'artifacts','backend\bin'){Ensure-HarnessOutputDirectory (Join-Path $Source $folder)}
$directory=New-HarnessEvidenceDirectory $OutRoot 'high-io-inspect'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class RooIndustriesInspectCapture {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f,IntPtr l);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 public static void Click(int x,int y,bool right){SetCursorPos(x,y);mouse_event(right?0x0008u:0x0002u,0,0,0,UIntPtr.Zero);mouse_event(right?0x0010u:0x0004u,0,0,0,UIntPtr.Zero);}
 public static IntPtr Window(int pid,string type){IntPtr found=IntPtr.Zero;EnumWindows((h,l)=>{uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)return true;var name=new StringBuilder(256);GetClassName(h,name,256);if(name.ToString()!=type)return true;found=h;return false;},IntPtr.Zero);return found;}
}
'@
[RooIndustriesInspectCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
function Is($Property,$Value){[Windows.Automation.PropertyCondition]::new($Property,$Value)}
function Both($Left,$Right){[Windows.Automation.AndCondition]::new($Left,$Right)}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function Named($Root,[string]$Name,$Type){$Root.FindFirst($TS::Descendants,(Both (Is $A::NameProperty $Name) (Is $A::ControlTypeProperty $Type)))}
function Windows([int]$ProcessId){@($A::RootElement.FindAll($TS::Children,(Is $A::ProcessIdProperty $ProcessId)))}
function Center($Element){$r=$Element.Current.BoundingRectangle;return @([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2))}
function Press($Element,[switch]$Right){$at=Center $Element;[RooIndustriesInspectCapture]::Click($at[0],$at[1],$Right.IsPresent);Start-Sleep -Milliseconds 400}
function Front($Element){$hwnd=[IntPtr]::new([long]$Element.Current.NativeWindowHandle);[RooIndustriesInspectCapture]::ShowWindow($hwnd,9)|Out-Null;[RooIndustriesInspectCapture]::SetForegroundWindow($hwnd)|Out-Null;Start-Sleep -Milliseconds 500}
function Shot($Element,[string]$Name){
 $r=$Element.Current.BoundingRectangle;$path=Join-Path $directory $Name
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 return $Name
}
function Tree($Root,[string]$Name){
 $rows=@($Root.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Select-Object -First 2500|ForEach-Object {$c=$_.Current;[ordered]@{type=$c.ControlType.ProgrammaticName;name=$c.Name;id=$c.AutomationId;class=$c.ClassName;rect=[string]$c.BoundingRectangle}})
 Write-HarnessResult $directory $Name $rows|Out-Null
}
function Note([string]$Text){[IO.File]::AppendAllText((Join-Path $directory 'progress.log'),[DateTime]::UtcNow.ToString('HH:mm:ss.fff')+' '+$Text+[Environment]::NewLine)}
function Mask($Checks){$mask=[uint64]0;foreach($check in $Checks){if($check.Current.Name -match '^CPU (\d+)$' -and $check.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On){$mask=$mask -bor ([uint64]1 -shl [int]$Matches[1])}};return $mask}
function TaskManager([int]$GamePid,[uint64]$Expected,[string]$Label){
 $result=[ordered]@{}
 $window=@(Windows ([int]$taskManager.Identity.pid)|Where-Object {$_.Current.ClassName -eq 'TaskManagerWindow'})[0]
 if(-not$window){throw 'The Task Manager window is not open.'}
 Front $window;Note 'task manager front'
 $details=WaitFor {Named $window 'Details' $CT::ListItem} 15 'the Details page'
 Press $details;Start-Sleep -Milliseconds 800;Note 'details page'
 $search=WaitFor {$window.FindFirst($TS::Descendants,(Is $A::ControlTypeProperty $CT::Edit))} 15 'the Task Manager search box'
 $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue([string]$GamePid);Note 'searched'
 $row=WaitFor {@($window.FindAll($TS::Descendants,(Is $A::ControlTypeProperty $CT::DataItem))|Where-Object {@($_.FindAll($TS::Descendants,(Is $A::NameProperty ([string]$GamePid)))).Count})[0]} 20 'the game row in Details'
 $result.row=$row.Current.Name;Note ('row '+$result.row)
 Press $row;Press $row -Right;Note 'context menu'
 $item=WaitFor {foreach($w in Windows ([int]$taskManager.Identity.pid)){$found=Named $w 'Set affinity' $CT::MenuItem;if($found){$found}}} 10 'Set affinity in the context menu'
 Press $item;Note 'set affinity clicked'
 $dialog=WaitFor {@(Windows ([int]$taskManager.Identity.pid)|Where-Object {$_.Current.Name -eq 'Processor affinity'})[0]} 15 'the Processor affinity dialog'
 Note 'affinity dialog'
 Start-Sleep -Milliseconds 500
 $checks=@($dialog.FindAll($TS::Descendants,(Is $A::ControlTypeProperty $CT::CheckBox)))
 $seen=Mask $checks
 $result.checked=@($checks|Where-Object {$_.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On}|ForEach-Object {$_.Current.Name})
 $result.mask='0x'+$seen.ToString('X');$result.matches=$seen -eq $Expected
 $result.dialog=Shot $dialog ('task-manager-affinity-'+$Label+'.png')
 $result.window=Shot $window ('task-manager-details-'+$Label+'.png')
 Press (Named $dialog 'Cancel' $CT::Button);Note 'affinity dialog cancelled'
 WaitFor {-not@(Windows ([int]$taskManager.Identity.pid)|Where-Object {$_.Current.Name -eq 'Processor affinity'}).Count} 10 'the affinity dialog to close'|Out-Null
 return $result
}
function ExplorerColumns{
 $window=$A::FromHandle($explorerWindow);Front $window
 $view=WaitFor {Named $window 'View' $CT::MenuItem} 15 'the View menu'
 Press $view;Note 'view menu'
 $select=WaitFor {foreach($w in Windows ([int]$explorer.Identity.pid)){$found=$w.FindFirst($TS::Descendants,(Both (Is $A::ControlTypeProperty $CT::MenuItem) (Is $A::NameProperty 'Select Columns...')));if($found){$found}}} 10 'Select Columns'
 Press $select;Note 'select columns clicked'
 $dialog=WaitFor {@(Windows ([int]$explorer.Identity.pid)|Where-Object {$_.Current.Name -eq 'Select Columns'})[0]} 15 'the Select Columns dialog'
 Note 'columns dialog'
 Tree $dialog 'process-explorer-columns-tree.json'
 $tab=WaitFor {Named $dialog 'Process Performance' $CT::TabItem} 10 'the Process Performance tab'
 Press $tab
 $box=WaitFor {Named $dialog 'I/O Priority' $CT::CheckBox} 10 'the I/O Priority column'
 $toggle=$box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){Press $box}
 $shot=Shot $dialog 'process-explorer-columns.png'
 Press (Named $dialog 'OK' $CT::Button);Note 'columns set'
 return $shot
}
function Explorer([int]$GamePid,[string]$Label){
 $result=[ordered]@{}
 $window=$A::FromHandle($explorerWindow);Front $window
 $row=WaitFor {@($window.FindAll($TS::Descendants,(Is $A::ControlTypeProperty $CT::ListItem))|Where-Object {$_.Current.Name -like 'RooIndustriesLaunchPolicyProbe*'})[0]} 20 'the game row in Process Explorer'
 try{$row.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 Press $row;Start-Sleep -Milliseconds 800
 $result.row=$row.Current.Name;Note ('explorer row '+$result.row)
 $result.cells=@($row.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.Name})
 $result.window=Shot $window ('process-explorer-'+$Label+'.png')
 return $result
}
$evidence=[ordered]@{inspectSeconds=$InspectSeconds;pauses=@()}
$test=$null;$taskManager=$null;$explorer=$null;$explorerWindow=[IntPtr]::Zero;$status='fail'
$settingsPath='Software\Sysinternals\Process Explorer';$parentPath='Software\Sysinternals'
$parentExisted=$null -ne [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parentPath)
$settingsExisted=$null -ne [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($settingsPath)
$taskManagerPath='Software\Microsoft\Windows\CurrentVersion\TaskManager'
$taskManagerKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($taskManagerPath)
$taskManagerBefore=@{};if($taskManagerKey){foreach($name in $taskManagerKey.GetValueNames()){$taskManagerBefore[$name]=@{kind=$taskManagerKey.GetValueKind($name);data=$taskManagerKey.GetValue($name,$null,'DoNotExpandEnvironmentNames')}};$taskManagerKey.Dispose()}
try{
 if($settingsExisted){throw 'Process Explorer settings already exist for this Windows user; this capture does not change them.'}
 if(@(Get-Process -Name Taskmgr,procexp,procexp64 -ErrorAction SilentlyContinue).Count){throw 'Task Manager or Process Explorer is already open; this capture does not take over another window.'}
 $signature=Get-AuthenticodeSignature -LiteralPath $ProcessExplorer
 if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'){throw 'Process Explorer needs a valid Microsoft signature.'}
 $evidence.processExplorer=[ordered]@{version=(Get-Item -LiteralPath $ProcessExplorer).VersionInfo.FileVersion;signer=$signature.SignerCertificate.Subject;elevated=$false}
 $copy=Join-Path $directory 'procexp64.exe';Copy-HarnessFile $ProcessExplorer $copy 'process-explorer'|Out-Null
 $dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
 if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
 $log=Join-Path $directory 'high-io.log';$runner=Join-Path $directory 'run-high-io.ps1'
 $shell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
 New-HarnessText $runner ("`$ErrorActionPreference='Continue'`n& '"+$shell+"' -NoProfile -ExecutionPolicy Bypass -File '"+(Join-Path $Source 'backend\scripts\Test-ProtectedGameSessions.ps1')+"' -DotNetPath '"+$dotnet[0]+"' -HighIo -InspectSeconds "+$InspectSeconds+" 2>&1|ForEach-Object {[IO.File]::AppendAllText('"+$log+"',[string]`$_+[Environment]::NewLine)}`n[IO.File]::AppendAllText('"+$log+"','RUNNER EXIT '+`$LASTEXITCODE+[Environment]::NewLine)") 'high-io-runner'|Out-Null
 $test=Start-OwnedProcess (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$runner+'"') 'Hidden' 'high-io-test'
 $taskManager=Start-OwnedProcess (Join-Path ([Environment]::SystemDirectory) 'Taskmgr.exe') '' 'Normal' 'task-manager'
 WaitFor {@(Windows ([int]$taskManager.Identity.pid)|Where-Object {$_.Current.ClassName -eq 'TaskManagerWindow'})[0]} 30 'Task Manager'|Out-Null
 $explorer=Start-HarnessExplorerProcess $copy '-accepteula' 'process-explorer'
 $explorerWindow=WaitFor {$h=[RooIndustriesInspectCapture]::Window([int]$explorer.Identity.pid,'PROCEXPL');if($h -ne [IntPtr]::Zero){$h}} 30 'Process Explorer'
 [RooIndustriesInspectCapture]::ShowWindow($explorerWindow,3)|Out-Null
 Note 'started';try{$evidence.processExplorer.columns=ExplorerColumns}catch{$evidence.processExplorer.columnsError=$_.Exception.Message;Tree ($A::FromHandle($explorerWindow)) 'process-explorer-tree.json'}
 $seen=0
 while($true){
  $lines=@();if(Test-Path -LiteralPath $log){$stream=[IO.FileStream]::new($log,'Open','Read','ReadWrite');try{$lines=@([IO.StreamReader]::new($stream).ReadToEnd() -split "`r?`n")}finally{$stream.Dispose()}}
  $pauses=@($lines|Where-Object {$_ -match '^INSPECT (.+?): game PID (\d+) for (\d+) s; expected I/O (\d), affinity 0x([0-9A-F]+)'})
  while($seen -lt $pauses.Count){
   $null=$pauses[$seen] -match '^INSPECT (.+?): game PID (\d+) for (\d+) s; expected I/O (\d), affinity 0x([0-9A-F]+)';$seen++
   $label=($Matches[1] -replace '[^A-Za-z0-9]+','-').ToLowerInvariant().Trim('-')
   $pause=[ordered]@{phase=$Matches[1];pid=[int]$Matches[2];expectedIo=[int]$Matches[4];expectedMask='0x'+$Matches[5];atUtc=[DateTime]::UtcNow.ToString('o');explorerRunning=-not$explorer.process.HasExited;taskManagerRunning=-not$taskManager.process.HasExited}
   Note ('pause '+$pause.phase)
   try{$pause.taskManager=TaskManager $pause.pid ([Convert]::ToUInt64($Matches[5],16)) $label}catch{$pause.taskManagerError=$_.Exception.Message;foreach($w in Windows ([int]$taskManager.Identity.pid)){Tree $w ('task-manager-tree-'+$label+'.json');break}}
   try{$pause.processExplorer=Explorer $pause.pid $label}catch{$pause.processExplorerError=$_.Exception.Message;Tree ($A::FromHandle($explorerWindow)) ('process-explorer-tree-'+$label+'.json')}
   $evidence.pauses+=@($pause)
  }
  if($test.process.HasExited){break}
  Start-Sleep -Milliseconds 300
 }
 $test.process.WaitForExit();$evidence.testExit=$test.process.ExitCode
 Copy-Item -LiteralPath (Join-Path $Source 'artifacts') -Destination (Join-Path $directory 'source-artifacts') -Recurse
 $evidence.testPassed=[bool](@($lines|Where-Object {$_ -match '^High I/O session assertions: \d+'}).Count)
 $failed=@($evidence.pauses|Where-Object {$_.taskManagerError -or $_.processExplorerError -or -not $_.taskManager.matches})
 if($evidence.pauses.Count -eq 3 -and -not$failed.Count -and $evidence.testPassed){$status='pass'}
}catch{
 $evidence.error=$_.Exception.Message
}finally{
 foreach($owned in @($explorer,$taskManager)){try{if($owned -and -not$owned.process.HasExited){Stop-HarnessProcess $owned}}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 if($test -and -not$test.process.HasExited){$test.process.WaitForExit(600000)|Out-Null}
 if(-not$settingsExisted -and [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($settingsPath)){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($settingsPath);$evidence.removedSettings=$settingsPath}
 $parent=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parentPath)
 if(-not$parentExisted -and $parent -and -not$parent.SubKeyCount -and -not$parent.ValueCount){$parent.Dispose();[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($parentPath);$evidence.removedSettings=$parentPath}elseif($parent){$parent.Dispose()}
 $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($taskManagerPath,$true)
 if($key){
  foreach($name in $key.GetValueNames()){if(-not$taskManagerBefore.ContainsKey($name)){$key.DeleteValue($name);$evidence.taskManagerRestored+=@($name)}}
  foreach($name in $taskManagerBefore.Keys){$old=$taskManagerBefore[$name];$now=$key.GetValue($name,$null,'DoNotExpandEnvironmentNames');if(($now -join ',') -cne ($old.data -join ',') -or $key.GetValueKind($name) -ne $old.kind){$key.SetValue($name,$old.data,$old.kind);$evidence.taskManagerRestored+=@($name)}}
  $key.Dispose()
 }
 $evidence.status=$status
 Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
 Write-Output ('ROO_INDUSTRIES_INSPECT_CAPTURE '+$status+' '+$directory)
}
if($status -ne 'pass'){exit 1}
