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
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class RooIndustriesInspectCapture {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct POINT{public int X,Y;}
 [StructLayout(LayoutKind.Sequential)] public struct RECT{public int L,T,R,B;}
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h,bool alt);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] public static extern IntPtr SendText(IntPtr h,uint m,IntPtr w,string l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] static extern IntPtr GetText(IntPtr h,uint m,IntPtr w,StringBuilder l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p,EnumProc f,IntPtr l);
 [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr m,int i);
 [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr m);
 [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr m,int i);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr m,uint id,StringBuilder s,int n,uint flags);
 [DllImport("user32.dll")] static extern bool GetMenuItemRect(IntPtr h,IntPtr m,uint i,out RECT r);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref POINT p);
 public static void Click(int x,int y,bool right){SetCursorPos(x,y);mouse_event(right?0x0008u:0x0002u,0,0,0,UIntPtr.Zero);mouse_event(right?0x0010u:0x0004u,0,0,0,UIntPtr.Zero);}
 public static string Class(IntPtr h){var s=new StringBuilder(256);GetClassName(h,s,256);return s.ToString();}
 public static string Text(IntPtr h){var s=new StringBuilder(512);GetText(h,0x000D,(IntPtr)512,s);return s.ToString().Replace("&","");}
 public static int Pid(IntPtr h){uint pid;GetWindowThreadProcessId(h,out pid);return (int)pid;}
 public static IntPtr Window(int pid,string type){IntPtr found=IntPtr.Zero;EnumWindows((h,l)=>{if(Pid(h)!=pid||Class(h)!=type)return true;found=h;return false;},IntPtr.Zero);return found;}
 public static IntPtr Top(int pid,string type,string title){IntPtr found=IntPtr.Zero;EnumWindows((h,l)=>{if(Pid(h)!=pid||Class(h)!=type||!IsWindowVisible(h)||Text(h)!=title)return true;found=h;return false;},IntPtr.Zero);return found;}
 public static IntPtr Child(IntPtr parent,string type,int id){IntPtr found=IntPtr.Zero;EnumChildWindows(parent,(h,l)=>{if(Class(h)==type&&GetDlgCtrlID(h)==id){found=h;return false;}return true;},IntPtr.Zero);return found;}
 public static IntPtr Labeled(IntPtr parent,string type,string text){IntPtr found=IntPtr.Zero;EnumChildWindows(parent,(h,l)=>{if(Class(h)==type&&Text(h)==text){found=h;return false;}return true;},IntPtr.Zero);return found;}
 public static List<string> Controls(IntPtr parent){var list=new List<string>();EnumChildWindows(parent,(h,l)=>{list.Add(Class(h)+"|"+GetDlgCtrlID(h)+"|"+IsWindowVisible(h)+"|"+Text(h));return true;},IntPtr.Zero);return list;}
 public static List<IntPtr> Buttons(IntPtr parent){var list=new List<IntPtr>();EnumChildWindows(parent,(h,l)=>{if(Class(h)=="Button")list.Add(h);return true;},IntPtr.Zero);return list;}
 public static uint MenuCommand(IntPtr window,string prefix){var bar=GetMenu(window);if(bar==IntPtr.Zero)return 0;for(int i=0;i<GetMenuItemCount(bar);i++){var sub=GetSubMenu(bar,i);if(sub==IntPtr.Zero)continue;for(int j=0;j<GetMenuItemCount(sub);j++){var text=new StringBuilder(256);GetMenuString(sub,(uint)j,text,256,0x400);var plain=text.ToString().Replace("&","").Split('\t')[0];if(plain.StartsWith(prefix,StringComparison.OrdinalIgnoreCase))return GetMenuItemID(sub,j);}}return 0;}
 // A shortcut menu is a #32768 window; MN_GETHMENU returns its menu, whose items are read and located without touching the other process's memory.
 public static int[] PopupItem(int pid,string prefix,List<string> seen){IntPtr popup=IntPtr.Zero;EnumWindows((h,l)=>{if(Class(h)=="#32768"&&IsWindowVisible(h)&&Pid(h)==pid){popup=h;return false;}return true;},IntPtr.Zero);if(popup==IntPtr.Zero)return null;var menu=SendMessage(popup,0x01E1,IntPtr.Zero,IntPtr.Zero);if(menu==IntPtr.Zero)return null;for(int i=0;i<GetMenuItemCount(menu);i++){var text=new StringBuilder(256);GetMenuString(menu,(uint)i,text,256,0x400);var plain=text.ToString().Replace("&","").Split('\t')[0];seen.Add(plain);if(plain.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)){RECT r;if(!GetMenuItemRect(IntPtr.Zero,menu,(uint)i,out r))return null;return new[]{(r.L+r.R)/2,(r.T+r.B)/2};}}return null;}
 public static IntPtr Beside(IntPtr parent,IntPtr label){RECT l;GetWindowRect(label,out l);IntPtr found=IntPtr.Zero;EnumChildWindows(parent,(h,x)=>{RECT b;if(Class(h)!="Button"||!IsWindowVisible(h)||!GetWindowRect(h,out b))return true;if(Math.Abs((b.T+b.B)/2-(l.T+l.B)/2)<=4&&b.L<l.L&&l.L-b.L<=40){found=h;return false;}return true;},IntPtr.Zero);return found;}
 public static int[] Client(IntPtr h){RECT r;GetClientRect(h,out r);var p=new POINT();ClientToScreen(h,ref p);return new[]{p.X,p.Y,p.X+r.R,p.Y+r.B};}
 public static int[] Bounds(IntPtr h){RECT r;GetWindowRect(h,out r);return new[]{r.L,r.T,r.R,r.B};}
}
'@
[RooIndustriesInspectCapture]::SetProcessDPIAware()|Out-Null
$U32=[RooIndustriesInspectCapture]
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
function Is($Property,$Value){[Windows.Automation.PropertyCondition]::new($Property,$Value)}
function Both($Left,$Right){[Windows.Automation.AndCondition]::new($Left,$Right)}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function Named($Root,[string]$Name,$Type){$Root.FindFirst($TS::Descendants,(Both (Is $A::NameProperty $Name) (Is $A::ControlTypeProperty $Type)))}
function Windows([int]$ProcessId){@($A::RootElement.FindAll($TS::Children,(Is $A::ProcessIdProperty $ProcessId)))}
function Center($Element){$r=$Element.Current.BoundingRectangle;return @([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2))}
function Press($Element,[switch]$Right){$at=Center $Element;$U32::Click($at[0],$at[1],$Right.IsPresent);Start-Sleep -Milliseconds 400}
function Choose($Element){try{$Element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Milliseconds 400}catch{Press $Element}}
function Note([string]$Text){[IO.File]::AppendAllText((Join-Path $directory 'progress.log'),[DateTime]::UtcNow.ToString('HH:mm:ss.fff')+' '+$Text.Replace($env:USERNAME,'<user>').Replace($env:COMPUTERNAME,'<pc-name>')+[Environment]::NewLine)}
# UI Automation sees this PC's classic Win32 controls only as plain panes, so dialogs, check boxes, tabs and menus are read with their own window messages.
# Bring one tool window to the front and minimize the other, so a maximized Process Explorer never sits on top of Task Manager.
function Front([IntPtr]$Handle,[IntPtr]$Other,[int]$Show=9){
 if($Other -ne [IntPtr]::Zero){$U32::ShowWindow($Other,6)|Out-Null}
 $U32::ShowWindow($Handle,$Show)|Out-Null;$U32::SetForegroundWindow($Handle)|Out-Null;Start-Sleep -Milliseconds 300
 if($U32::GetForegroundWindow() -ne $Handle){$U32::SwitchToThisWindow($Handle,$true);Start-Sleep -Milliseconds 300}
 Note ('front '+($U32::GetForegroundWindow() -eq $Handle));Start-Sleep -Milliseconds 300
}
function Handle($Element){[IntPtr]::new([long]$Element.Current.NativeWindowHandle)}
function ShotRect([int[]]$Rect,[string]$Name){
 $path=Join-Path $directory $Name
 $bitmap=[Drawing.Bitmap]::new($Rect[2]-$Rect[0],$Rect[3]-$Rect[1]);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen($Rect[0],$Rect[1],0,0,$bitmap.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 return $Name
}
function Tree($Root,[string]$Name){
 $rows=@($Root.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Select-Object -First 2500|ForEach-Object {$c=$_.Current;[ordered]@{type=$c.ControlType.ProgrammaticName;name=$c.Name;id=$c.AutomationId;class=$c.ClassName;rect=[string]$c.BoundingRectangle}})
 Write-HarnessResult $directory $Name $rows|Out-Null
}
function Mask($Checks){$mask=[uint64]0;foreach($check in $Checks){if($check.Current.Name -match '^CPU (\d+)$' -and $check.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On){$mask=$mask -bor ([uint64]1 -shl [int]$Matches[1])}};return $mask}
function TaskManagerWindow{$found=@(Windows ([int]$taskManager.Identity.pid)|Where-Object {$_.Current.ClassName -eq 'TaskManagerWindow'})[0];if(-not$found){throw 'The Task Manager window is not open.'};$found}
function TaskManager([int]$GamePid,[uint64]$Expected,[string]$Label){
 $result=[ordered]@{};$tm=[int]$taskManager.Identity.pid
 $window=TaskManagerWindow
 Front (Handle $window) $explorerWindow 3;Note 'task manager front'
 $details=WaitFor {Named $window 'Details' $CT::ListItem} 15 'the Details page'
 $selected={try{$details.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected}catch{$false}}
 if(-not(& $selected)){Choose $details;try{WaitFor $selected 8 'the Details page'|Out-Null}catch{Press $details;WaitFor $selected 8 'the Details page after a click'|Out-Null}}
 Note 'details page'
 # Search before looking for the list: a search left over from an earlier, closed game copy shows no list at all.
 $search=WaitFor {$window.FindFirst($TS::Descendants,(Is $A::ControlTypeProperty $CT::Edit))} 15 'the Task Manager search box'
 $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue([string]$GamePid);Note 'searched';Start-Sleep -Milliseconds 1500
 $list={$window.FindFirst($TS::Descendants,(Is $A::AutomationIdProperty 'cpuList'))}
 WaitFor $list 10 'the Details list'|Out-Null
 Front (Handle $window) $explorerWindow 3
 # The search leaves only the game's row, the first row under the column header.
 $grid=& $list;$g=$grid.Current.BoundingRectangle
 $header=$grid.FindFirst($TS::Descendants,(Is $A::ClassNameProperty 'SysHeader32'));$top=if($header){[int]$header.Current.BoundingRectangle.Bottom}else{[int]$g.Y+24}
 $x=[int]$g.X+60;$y=$top+10;$result.rowPoint="$x,$y"
 $U32::Click($x,$y,$false);Start-Sleep -Milliseconds 400;$U32::Click($x,$y,$true);Start-Sleep -Milliseconds 600;Note 'context menu'
 $seen=[Collections.Generic.List[string]]::new()
 $at=WaitFor {$seen.Clear();$U32::PopupItem($tm,'Set affinity',$seen)} 10 'Set affinity in the context menu'
 $result.menu=@($seen);$U32::Click($at[0],$at[1],$false);Note 'set affinity clicked'
 # Windows 11 shows Processor affinity as a dialog inside the Task Manager window.
 $dialog=WaitFor {$d=$window.FindFirst($TS::Descendants,(Is $A::AutomationIdProperty 'ProcessorAffinityDialog'));if($d -and -not$d.Current.BoundingRectangle.IsEmpty){$d}} 15 'the Processor affinity dialog'
 Note 'affinity dialog';Start-Sleep -Milliseconds 700
 $checks=@($dialog.FindAll($TS::Descendants,(Is $A::ControlTypeProperty $CT::CheckBox)))
 $seenMask=Mask $checks
 $result.checked=@($checks|Where-Object {$_.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On}|ForEach-Object {$_.Current.Name})
 $result.mask='0x'+$seenMask.ToString('X');$result.matches=$seenMask -eq $Expected
 $r=$dialog.Current.BoundingRectangle;$box=@([int]$r.X,[int]$r.Y,[int]$r.Right,[int]$r.Bottom)
 # The dialog keeps its scroll position between openings: start every set at the top of the list.
 $first=@($checks|Where-Object {$_.Current.Name -eq 'All Processors'})[0]
 if($first){try{$first.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView();Start-Sleep -Milliseconds 500}catch{$result.scrollError=$_.Exception.Message}}
 # Task Manager's User name column names the Windows account; this full-window image is cropped on the Linux host before it is kept.
 $result.window=ShotRect ($U32::Bounds((Handle $window))) ('task-manager-details-'+$Label+'.png')
 $result.dialog=@(ShotRect $box ('task-manager-affinity-'+$Label+'.png'))
 # The list scrolls: also show the first CPU outside the mask and the last CPU.
 $edge=0;while($edge -lt 64 -and ($Expected -band ([uint64]1 -shl $edge))){$edge++}
 foreach($name in ('CPU '+$edge),('CPU '+($checks.Count-2))){
  $cpu=@($checks|Where-Object {$_.Current.Name -eq $name})[0]
  if($cpu){try{$cpu.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView();Start-Sleep -Milliseconds 500;$result.dialog+=ShotRect $box ('task-manager-affinity-'+$Label+'-'+($name -replace ' ','').ToLowerInvariant()+'.png')}catch{$result.scrollError=$_.Exception.Message}}
 }
 $cancel=Named $dialog 'Cancel' $CT::Button
 try{$cancel.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{Press $cancel};Note 'affinity dialog cancelled'
 WaitFor {$d=$window.FindFirst($TS::Descendants,(Is $A::AutomationIdProperty 'ProcessorAffinityDialog'));-not$d -or $d.Current.BoundingRectangle.IsEmpty} 10 'the affinity dialog to close'|Out-Null
 return $result
}
# Process Explorer 17 exposes neither its menu bar nor its process list to UI Automation: open Select Columns through the window's own menu command and filter the list by name.
function ExplorerColumns{
 $pe=[int]$explorer.Identity.pid;$result=[ordered]@{}
 Front $explorerWindow (Handle (TaskManagerWindow)) 3
 $command=$U32::MenuCommand($explorerWindow,'Select Columns')
 if(-not$command){throw 'Process Explorer has no Select Columns menu command.'}
 $U32::PostMessage($explorerWindow,0x0111,[IntPtr][int]$command,[IntPtr]::Zero)|Out-Null;Note ('select columns command '+$command)
 $dialog=WaitFor {$h=$U32::Top($pe,'#32770','Select Columns');if($h -ne [IntPtr]::Zero){$h}} 15 'the Select Columns dialog'
 Note 'columns dialog'
 $tabs=$U32::Child($dialog,'SysTabControl32',12320);$count=[int]$U32::SendMessage($tabs,0x1304,[IntPtr]::Zero,[IntPtr]::Zero)
 $box=[IntPtr]::Zero
 $all=@()
 for($i=0;$i -lt $count;$i++){
  $U32::SendMessage($tabs,0x1330,[IntPtr]$i,[IntPtr]::Zero)|Out-Null;Start-Sleep -Milliseconds 400
  $visible=@($U32::Controls($dialog)|Where-Object {$_ -like '*|True|*'});$all+=("tab "+$i);$all+=$visible
  # Process Explorer 17.2 names the I/O priority column just Priority, on its Process I/O tab next to Read Bytes.
  $box=$U32::Labeled($dialog,'Button','I/O Priority')
  if($box -eq [IntPtr]::Zero){$reads=$U32::Labeled($dialog,'Button','Read Bytes');if($reads -ne [IntPtr]::Zero -and $U32::IsWindowVisible($reads)){$box=$U32::Labeled($dialog,'Button','Priority')}}
  if($box -ne [IntPtr]::Zero -and $U32::IsWindowVisible($box)){$result.tab=$i;break};$box=[IntPtr]::Zero
 }
 Write-HarnessResult $directory 'process-explorer-columns-controls.json' $all|Out-Null
 if($box -eq [IntPtr]::Zero){$result.controls=@($U32::Controls($dialog));throw 'The I/O Priority column was not found on any Select Columns tab.'}
 if([int]$U32::SendMessage($box,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero) -ne 1){$U32::SendMessage($box,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;Start-Sleep -Milliseconds 300}
 $result.ioPriorityChecked=[int]$U32::SendMessage($box,0x00F0,[IntPtr]::Zero,[IntPtr]::Zero) -eq 1
 $result.shot=ShotRect ($U32::Bounds($dialog)) 'process-explorer-columns.png'
 $ok=$U32::Child($dialog,'Button',1);$U32::PostMessage($dialog,0x0111,[IntPtr]1,$ok)|Out-Null
 WaitFor {$U32::Top($pe,'#32770','Select Columns') -eq [IntPtr]::Zero} 10 'the Select Columns dialog to close'|Out-Null;Note ('columns set '+$result.ioPriorityChecked)
 $filter=$U32::Child($explorerWindow,'Edit',113)
 if($filter -eq [IntPtr]::Zero){throw 'Process Explorer has no name filter box.'}
 $U32::SendText($filter,0x000C,[IntPtr]::Zero,'RooIndustries')|Out-Null
 $notify=[IntPtr](0x03000000 -bor 113);foreach($target in $U32::GetParent($filter),$explorerWindow){$U32::PostMessage($target,0x0111,$notify,$filter)|Out-Null}
 $result.filter=$U32::Text($filter);Note ('filtered '+$result.filter)
 return $result
}
function Explorer([int]$GamePid,[string]$Label){
 $result=[ordered]@{}
 Front $explorerWindow (Handle (TaskManagerWindow)) 3
 Start-Sleep -Milliseconds 2500
 # The client area leaves out the title bar, which names the PC and the Windows account.
 $result.window=ShotRect ($U32::Client($explorerWindow)) ('process-explorer-'+$Label+'.png')
 Note ('explorer shot '+$Label)
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
 $explorerWindow=WaitFor {$h=[RooIndustriesInspectCapture]::Window([int]$explorer.Identity.pid,'PROCEXPLORER');if($h -ne [IntPtr]::Zero){$h}} 30 'Process Explorer'
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
