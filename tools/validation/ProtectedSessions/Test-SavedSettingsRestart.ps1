param(
    [Parameter(Mandatory)][ValidateSet('Save','Check','TurnOff')][string]$Phase,
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$OutRoot,
    [string]$Launcher='', [string]$Game='', [string]$GameStart='', [string]$Preset='Competitive', [string]$Cores='', [string]$DiskPriority=''
)
# Saved launch settings across a real Windows restart, with a real launcher and game.
# Save: the app saves settings for the running launcher and closes its window. Restart Windows and sign in, open nothing.
# Check: the sign-in start runs the app without a window, the launcher's run gets the saved settings, and the game started
# through the launcher has them. TurnOff: the app opens, turns the settings off and removes its sign-in start.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesRestartCheck {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessAffinityMask(IntPtr p,out UIntPtr mask,out UIntPtr system);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetPriorityClass(IntPtr p);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessPriorityBoost(IntPtr p,out bool disabled);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr p,int kind,ref int value,int size,IntPtr returned);
 static IntPtr Open(int pid){var h=OpenProcess(0x1000,false,pid);if(h==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();return h;}
 public static ulong Affinity(int pid){var h=Open(pid);try{UIntPtr mask,system;if(!GetProcessAffinityMask(h,out mask,out system))throw new System.ComponentModel.Win32Exception();return mask.ToUInt64();}finally{CloseHandle(h);}}
 public static uint Priority(int pid){var h=Open(pid);try{var value=GetPriorityClass(h);if(value==0)throw new System.ComponentModel.Win32Exception();return value;}finally{CloseHandle(h);}}
 public static bool BoostOn(int pid){var h=Open(pid);try{bool disabled;if(!GetProcessPriorityBoost(h,out disabled))throw new System.ComponentModel.Win32Exception();return !disabled;}finally{CloseHandle(h);}}
 public static int Io(int pid){var h=Open(pid);try{int value=0;var status=NtQueryInformationProcess(h,33,ref value,4,IntPtr.Zero);if(status!=0)throw new InvalidOperationException("I/O priority query failed: 0x"+status.ToString("X8"));return value;}finally{CloseHandle(h);}}
}
'@
[RooIndustriesRestartCheck]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$App=[IO.Path]::GetFullPath($App)
# The app's own backend says which data folder it uses: an older folder name stays where it already exists.
$backend=Split-Path $App -Parent
while($backend -and -not(Test-Path -LiteralPath (Join-Path $backend 'backend\scripts\BrandCompatibility.Common.ps1'))){$backend=Split-Path $backend -Parent}
if(-not $backend){throw 'The app''s backend scripts were not found above the app.'}
. (Join-Path $backend 'backend\scripts\BrandCompatibility.Common.ps1')
$operations=Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$savedPath=Join-Path $OutRoot 'saved.json'
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$evidence=[ordered]@{phase=$Phase;app=$App;startedUtc=[DateTime]::UtcNow.ToString('o');bootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');steps=@();unexpected=@()}
$window=$null
function Save-Evidence{($evidence|ConvertTo-Json -Depth 12)|Set-Content -LiteralPath (Join-Path $OutRoot ($Phase.ToLowerInvariant()+'.json')) -Encoding UTF8}
function Expect([string]$Step,[bool]$Ok,[string]$What){$script:evidence.steps+=@([ordered]@{step=$Step;ok=$Ok;what=$What;atUtc=[DateTime]::UtcNow.ToString('o')});if(-not$Ok){$script:evidence.unexpected+=@($Step+': '+$What)}}
function WaitFor([scriptblock]$Check,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Check}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 500};throw ('Timed out waiting for '+$What)}
function AppProcesses{@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($App)) -ErrorAction SilentlyContinue|Where-Object {$_.Path -ieq $App})}
# Only a real window counts: a tooltip the app shows is a top-level element too.
function AppWindow([int]$Id){$A::RootElement.FindFirst($TS::Children,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$Id),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Window)))}
function ById([string]$Id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Text([string]$Id){$e=ById $Id;if($e){$e.Current.Name}else{$null}}
function Enabled([string]$Id){$e=ById $Id;if($e -and $e.Current.IsEnabled){$e}}
function Invoke($Element){try{$Element.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};$Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();Start-Sleep -Milliseconds 400}
function Choose($Box,[string]$Pattern,[string]$What){
 # Lists are virtualized: walk every item through ItemContainerPattern, realize the match, then select it and confirm the list's own selection.
 $expand=$Box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
 for($try=0;$try -lt 6;$try++){
  try{$expand.Expand()}catch{};Start-Sleep -Milliseconds 600
  $item=$null
  try{$container=$Box.GetCurrentPattern([Windows.Automation.ItemContainerPattern]::Pattern);$next=$null;do{$next=$container.FindItemByProperty($next,$null,$null);if($next -and $next.Current.Name -like $Pattern){$item=$next}}while($next -and -not$item)}catch{}
  if(-not$item){$item=@($Box.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {$_.Current.Name -like $Pattern})[0]}
  if(-not$item){continue}
  try{$item.GetCurrentPattern([Windows.Automation.VirtualizedItemPattern]::Pattern).Realize()}catch{}
  try{$item.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};Start-Sleep -Milliseconds 300
  try{$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}catch{try{$item.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{}}
  Start-Sleep -Milliseconds 600;try{$expand.Collapse()}catch{}
  $picked=@($Box.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()|ForEach-Object {$_.Current.Name})
  if($picked -like $Pattern){return $picked[0]}
 }
 $names=@();try{$container=$Box.GetCurrentPattern([Windows.Automation.ItemContainerPattern]::Pattern);$next=$null;do{$next=$container.FindItemByProperty($next,$null,$null);if($next){$names+=$next.Current.Name}}while($next -and $names.Count -lt 400)}catch{}
 throw ('Could not choose '+$What+' ('+$Pattern+'); the list had: '+(($names|Select-Object -First 12) -join ' | '))
}
function Shot([string]$Name){
 $bounds=if($window){$r=$window.Current.BoundingRectangle;[Drawing.Rectangle]::new([int]$r.X,[int]$r.Y,[int]$r.Width,[int]$r.Height)}else{[Windows.Forms.Screen]::PrimaryScreen.Bounds}
 $b=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$g=[Drawing.Graphics]::FromImage($b)
 try{$g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$b.Size);$b.Save((Join-Path $OutRoot ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
}
function Open-AppWindow{
 # Opening the app shows its window, or hands over to the copy that is already running, which then shows it.
 $env:ROO_INDUSTRIES_INITIAL_NAV='profiles'
 $opened=Start-Process -FilePath $App -WorkingDirectory (Split-Path $App -Parent) -PassThru
 $script:window=WaitFor {foreach($p in AppProcesses){$w=AppWindow $p.Id;if($w){$w}}} 180 'the app window'
 $hwnd=[IntPtr]::new([long]$script:window.Current.NativeWindowHandle)
 [RooIndustriesRestartCheck]::SetWindowPos($hwnd,[IntPtr]::new(-1),20,20,1400,1000,0x40)|Out-Null;[RooIndustriesRestartCheck]::SetForegroundWindow($hwnd)|Out-Null
 # A release build ignores the start-page switch and opens on Home: pick Games in the menu.
 $games=$null;try{$games=WaitFor {ById 'GamesTab'} 15 'the Games tab'}catch{}
 if(-not $games){
  $nav=WaitFor {@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Games'))|Where-Object {$_.Current.ControlType -eq $CT::ListItem})[0]} 60 'Games in the menu'
  try{$nav.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}catch{$nav.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
  $games=WaitFor {ById 'GamesTab'} 120 'the Games tab'
 }
 Start-Sleep -Seconds 2
 $later=ById 'UpdateLaterButton';if($later){Invoke $later}
 $games.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Seconds 2
 return $opened
}
function SignInStart{@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like 'Performance Vertex Utility Saved Launch Settings *' -and $_.Description -ieq ('Performance Vertex Utility saved launch settings | '+$owner+' | '+$operations)})}
function Profiles{@(if([IO.Directory]::Exists($operations)){[IO.Directory]::GetDirectories($operations,'launch-profile-*')})}
function State([string]$Root){$file=Join-Path $Root 'state.json';if([IO.File]::Exists($file)){[IO.File]::ReadAllText($file)|ConvertFrom-Json}}
$status='fail'
try{
 if($Phase -eq 'Save'){
  if(-not $Launcher -or -not $Game){throw 'Save needs -Launcher and -Game.'}
  if(AppProcesses){throw 'Close the app first; Save starts it.'}
  if(Profiles){throw 'Saved launch settings already exist; turn them off first.'}
  $launcherName=[IO.Path]::GetFileNameWithoutExtension($Launcher)
  if(-not @(Get-Process -Name $launcherName -ErrorAction SilentlyContinue|Where-Object {$_.Path -ieq $Launcher}).Count){throw ('Start '+$launcherName+' first.')}
  Open-AppWindow|Out-Null
  Invoke (WaitFor {Enabled 'GameSessionNew'} 60 'New on Games')
  (WaitFor {Enabled 'GameSessionExecutable'} 60 'the game file box').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Game);Start-Sleep -Milliseconds 500
  Invoke (WaitFor {Enabled 'GameSessionRefresh'} 30 'Refresh')
  $evidence.launcher=Choose (WaitFor {Enabled 'GameSessionLauncher'} 60 'the launcher list') ($launcherName+'*') 'the launcher'
  $evidence.preset=Choose (WaitFor {Enabled 'GameSessionPreset'} 60 'the preset list') ($Preset+'*') 'the preset'
  if($DiskPriority){
   # Each launch priority is a list named after its setting; changing one turns the preset into Custom.
   $disk=WaitFor {$e=$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'Disk priority'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ComboBox)));if($e -and $e.Current.IsEnabled){$e}} 60 'the disk priority list'
   $evidence.diskPriority=Choose $disk ($DiskPriority+'*') 'the disk priority'
  }
  if($Cores){
   # Core choices are buttons named after the cores they pick, such as Performance cores or Cache group 1.
   $choice=WaitFor {@($window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'GameSessionCoreChoice'))|Where-Object {$_.Current.Name -like $Cores -and $_.Current.IsEnabled})[0]} 60 'the core choice'
   $evidence.cores=$choice.Current.Name;Invoke $choice
   Start-Sleep -Seconds 1;$evidence.coresText=Text 'GameSessionCoresText'
  }
  $keep=WaitFor {Enabled 'GameSessionKeep'} 30 'Save for next time'
  if($keep.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$keep.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()}
  Invoke (WaitFor {Enabled 'GameSessionPreview'} 60 'Review changes')
  $evidence.review=WaitFor {Text 'GameSessionReview'} 180 'the review'
  Invoke (WaitFor {Enabled 'GameSessionStart'} 60 'Start')
  WaitFor {(Text 'GameSessionStatus') -like 'Ready*'} 120 'the session to be ready'|Out-Null
  $evidence.row=WaitFor {Text 'GameSessionProfileStatus'} 60 'the saved settings row'
  Shot 'saved'
  $profile=@(Profiles)
  Expect 'saved' ($profile.Count -eq 1) 'one set of saved launch settings'
  $preview=[IO.File]::ReadAllText((Join-Path $profile[0] 'reviewed-preview.json'))|ConvertFrom-Json
  $evidence.controls=$preview.controls
  $task=@(SignInStart)
  Expect 'saved' ($task.Count -eq 1 -and "$($task[0].Actions[0].Arguments)".Contains($App+'?--saved-settings')) 'Save adds the sign-in start for this app'
  $id=$window.Current.ProcessId
  $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();$window=$null
  Start-Sleep -Seconds 5
  Expect 'saved' ([bool](Get-Process -Id $id -ErrorAction SilentlyContinue) -and -not(AppWindow $id)) 'closing the window leaves the app running without a window'
  @{savedUtc=[DateTime]::UtcNow.ToString('o');profile=$profile[0];controls=$preview.controls;game=$Game;launcher=$Launcher}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $savedPath -Encoding UTF8
 }
 if($Phase -eq 'Check'){
  $saved=Get-Content -Raw -LiteralPath $savedPath|ConvertFrom-Json
  $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
  Expect 'restart' ($boot -gt [DateTime]::Parse($saved.savedUtc).ToUniversalTime()) ('Windows restarted after Save (boot '+$boot.ToString('o')+')')
  $running=@(AppProcesses)
  Expect 'sign-in' ($running.Count -eq 1 -and $running[0].StartTime.ToUniversalTime() -gt $boot) 'the sign-in start runs the app after the restart'
  Expect 'sign-in' (-not @($running|Where-Object {AppWindow $_.Id}).Count) 'nobody opened it: the app runs without a window'
  $launcherName=[IO.Path]::GetFileNameWithoutExtension($saved.launcher)
  $launch=WaitFor {@(Get-Process -Name $launcherName -ErrorAction SilentlyContinue|Where-Object {$_.Path -ieq $saved.launcher}|Sort-Object StartTime)[0]} 180 'the launcher to start after sign-in'
  $state=WaitFor {$s=State $saved.profile;if($s -and $s.status -eq 'armed' -and $s.launcher.processId -eq $launch.Id){$s}} 180 'the saved settings to turn on for the launcher'
  $evidence.state=$state
  Expect 'armed' ([bool]$state) 'the launcher''s run after the restart gets the saved settings'
  if($GameStart){Start-Process $GameStart}
  $gameName=[IO.Path]::GetFileNameWithoutExtension($saved.game)
  $played=WaitFor {@(Get-Process -Name $gameName -ErrorAction SilentlyContinue|Where-Object {$_.Path -ieq $saved.game})[0]} 300 'the game to start'
  Start-Sleep -Seconds 20
  $classes=@{Idle=64;BelowNormal=16384;Normal=32;AboveNormal=32768;High=128;RealTime=256}
  $seen=[ordered]@{pid=$played.Id;priorityClass=[RooIndustriesRestartCheck]::Priority($played.Id);affinity=('0x{0:X}' -f [RooIndustriesRestartCheck]::Affinity($played.Id));io=[RooIndustriesRestartCheck]::Io($played.Id);boost=[RooIndustriesRestartCheck]::BoostOn($played.Id)}
  $evidence.game=$seen
  $wanted=$saved.controls
  if($wanted.cpuPriority){Expect 'game' ($seen.priorityClass -eq $classes[[string]$wanted.cpuPriority]) ('the game runs at the saved CPU priority '+$wanted.cpuPriority)}
  if($wanted.affinity){$mask=[string]$wanted.affinity.mask;$cores=if($mask -match '^0[xX]'){[Convert]::ToUInt64($mask.Substring(2),16)}else{[UInt64]$mask};Expect 'game' ($seen.affinity -eq ('0x{0:X}' -f $cores)) ('the game runs on the saved cores '+$mask)}
  if($null -ne $wanted.ioPriority){Expect 'game' ($seen.io -eq [int]$wanted.ioPriority) ('the game runs at the saved disk priority '+$wanted.ioPriority)}
  if($null -ne $wanted.priorityBoost){Expect 'game' ($seen.boost -eq [bool]$wanted.priorityBoost) ('the game''s priority boost is '+$wanted.priorityBoost)}
  $window=$null;Shot 'game-running'
  $session=Join-Path $state.sessionRoot 'session.json'
  if([IO.File]::Exists($session)){$evidence.sessionStatus=([IO.File]::ReadAllText($session)|ConvertFrom-Json).status}
 }
 if($Phase -eq 'TurnOff'){
  $before=@(AppProcesses|ForEach-Object {$_.Id})
  Open-AppWindow|Out-Null
  Expect 'turn-off' ($before.Count -eq 0 -or $before -contains $window.Current.ProcessId) 'opening the app shows the running copy''s window'
  WaitFor {ById 'GameSessionProfileStatus'} 60 'the saved settings row'|Out-Null
  Shot 'before-turn-off'
  Invoke (WaitFor {Enabled 'GameSessionProfileOff'} 30 'Turn off and restore')
  WaitFor {-not(ById 'GameSessionProfileStatus') -and (Text 'GameSessionStatus') -like 'Saved settings turned off*'} 90 'the settings to turn off'|Out-Null
  Shot 'turned-off'
  Expect 'turn-off' (-not @(SignInStart).Count -and -not @(Profiles).Count) 'turning off the last saved settings removes them and their sign-in start'
  $id=$window.Current.ProcessId
  $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();$window=$null
  Expect 'turn-off' ([bool](WaitFor {-not(Get-Process -Id $id -ErrorAction SilentlyContinue)} 30 'the app to end')) 'with nothing saved, closing the window ends the app'
 }
 if($evidence.unexpected.Count){throw ('Unexpected: '+($evidence.unexpected -join '; '))}
 $status='pass'
}catch{$evidence.error=$_.Exception.Message;try{Shot 'failure'}catch{}}
finally{$evidence.status=$status;Save-Evidence;Write-Output ('ROO_INDUSTRIES_SAVED_SETTINGS_RESTART '+$Phase+' '+$status+' '+$OutRoot)}
if($status -ne 'pass'){exit 1}
