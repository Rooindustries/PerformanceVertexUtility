param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label,[ValidateSet('full','link-review')][string]$Scenario='full')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('saved-settings-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('saved-settings-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesSavedSettingsUi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 public static void Click(int x,int y){SetCursorPos(x,y);mouse_event(0x0002u,0,0,0,UIntPtr.Zero);mouse_event(0x0004u,0,0,0,UIntPtr.Zero);}
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessAffinityMask(IntPtr p,out UIntPtr mask,out UIntPtr system);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr p,int kind,ref int value,int size,IntPtr returned);
 static IntPtr Open(int pid){var h=OpenProcess(0x1000,false,pid);if(h==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();return h;}
 public static ulong Affinity(int pid){var h=Open(pid);try{UIntPtr mask,system;if(!GetProcessAffinityMask(h,out mask,out system))throw new System.ComponentModel.Win32Exception();return mask.ToUInt64();}finally{CloseHandle(h);}}
 [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr token);
 [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr token,int kind,out int value,int length,out int returned);
 public static bool Elevated(int pid){var h=Open(pid);try{IntPtr t;if(!OpenProcessToken(h,8,out t))throw new System.ComponentModel.Win32Exception();try{int v,r;if(!GetTokenInformation(t,20,out v,4,out r))throw new System.ComponentModel.Win32Exception();return v!=0;}finally{CloseHandle(t);}}finally{CloseHandle(h);}}
 public static int Io(int pid){var h=Open(pid);try{int value=0;var status=NtQueryInformationProcess(h,33,ref value,4,IntPtr.Zero);if(status!=0)throw new InvalidOperationException("I/O priority query failed: 0x"+status.ToString("X8"));return value;}finally{CloseHandle(h);}}
}
'@
[RooIndustriesSavedSettingsUi]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$evidence=[ordered]@{label=$Label;steps=@();chooseWays=@();unexpected=@()};$status='fail';$imageLock=$null
$link=$null;$app=$null;$limited=$null;$window=$null;$recorder=$null;$owned=[Collections.Generic.List[object]]::new();$roots=[Collections.Generic.List[string]]::new();$copies=[Collections.Generic.List[object]]::new()
# The app's data folder: an older folder name stays in use where it already exists.
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
$operations=Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'
$before=@(if([IO.Directory]::Exists($operations)){[IO.Directory]::GetDirectories($operations)})
$ifeo='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesSavedGame.exe'
function TaskName([string]$Session){$sha=[Security.Cryptography.SHA256]::Create();try{'Roo Industries Protected Session '+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($Session)).ToLowerInvariant())))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}}
function SessionTasks{@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.Description -like ('Roo Industries protected game session | * | '+$operations+'\game-session-*')})}
$beforeTasks=@(SessionTasks|ForEach-Object {$_.TaskName})
function Leftovers{
 # A start that changed nothing must leave no session folder and no sign-in task behind.
 $folders=@(if([IO.Directory]::Exists($operations)){[IO.Directory]::GetDirectories($operations)|Where-Object {$before -notcontains $_ -and [IO.Path]::GetFileName($_) -like 'game-session-*'}|ForEach-Object {Join-Path $_ 'session'}|Where-Object {[IO.Directory]::Exists($_) -and -not[IO.File]::Exists((Join-Path $_ 'session.json'))}})
 $tasks=@(SessionTasks|Where-Object {$beforeTasks -notcontains $_.TaskName -and -not[IO.File]::Exists((Join-Path ($_.Description -split ' \| ')[-1] 'session.json'))}|ForEach-Object {$_.TaskName})
 return @($folders)+$tasks
}
function Expect([string]$Step,[bool]$Ok,[string]$What){if(-not$Ok){$script:evidence.unexpected+=@($Step+': '+$What)}}
function WaitFor([scriptblock]$Check,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Check}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function ById([string]$Id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Text([string]$Id){$e=ById $Id;if($e){$e.Current.Name}else{$null}}
function Invoke($Element){if(-not$Element){throw 'Missing UI element'};try{$Element.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};$Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();Start-Sleep -Milliseconds 400}
function Enabled([string]$Id){$e=ById $Id;if($e -and $e.Current.IsEnabled){$e}}
function Toggle($Element,[bool]$On){$t=$Element.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if(($t.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) -ne $On){try{$Element.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};$t.Toggle();Start-Sleep -Milliseconds 300}}
function Chosen($Box,[scriptblock]$Match){try{@($Box.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()|Where-Object {& $Match $_.Current.Name}).Count -gt 0}catch{$false}}
function Choose($Box,[scriptblock]$Match,[string]$What){
 # WinUI combo items are virtualized: realize, find the item again, then Select, Invoke or click it, and confirm the combo's own selection each time.
 if(-not$Box){throw ('Missing list for '+$What)}
 try{$Box.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 $expand=$Box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
 $picked=$null;$last='no matching choice'
 for($try=0;$try -lt 6 -and -not$picked;$try++){
  try{$expand.Expand()}catch{};Start-Sleep -Milliseconds 500
  $item=$null
  try{$container=$Box.GetCurrentPattern([Windows.Automation.ItemContainerPattern]::Pattern);$next=$null;do{$next=$container.FindItemByProperty($next,$null,$null);if($next -and (& $Match $next.Current.Name)){$item=$next}}while($next -and -not$item)}catch{}
  if(-not$item){$item=@($Box.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {& $Match $_.Current.Name})[0]}
  if(-not$item){Start-Sleep -Milliseconds 400;continue}
  try{$item.GetCurrentPattern([Windows.Automation.VirtualizedItemPattern]::Pattern).Realize()}catch{}
  try{$item.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};Start-Sleep -Milliseconds 300
  $fresh=@($Box.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {& $Match $_.Current.Name})[0];if($fresh){$item=$fresh}
  $label=$item.Current.Name
  foreach($way in 'select','invoke','click'){
   try{
    switch($way){
     'select'{$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}
     'invoke'{$item.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
     'click'{$r=$item.Current.BoundingRectangle;if($r.Width -le 0 -or $r.Height -le 0 -or $item.Current.IsOffscreen){throw 'item not on screen'};[RooIndustriesSavedSettingsUi]::Click([int]($r.X+$r.Width/2),[int]($r.Y+$r.Height/2))}
    }
   }catch{$last=$way+': '+$_.Exception.Message}
   Start-Sleep -Milliseconds 500
   if(Chosen $Box $Match){$picked=$label;$script:evidence.chooseWays+=@($What+' by '+$way);break}
  }
 }
 try{$expand.Collapse()}catch{}
 if(-not$picked){throw ('Could not choose '+$What+': '+$last)}
 Start-Sleep -Milliseconds 400
 return $picked
}
function Shot([string]$Name){$r=$window.Current.BoundingRectangle;$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$b.Size);$b.Save((Join-Path $directory ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()};return $Name+'.png'}
function Step([string]$Name,$Data){$entry=[ordered]@{step=$Name;atUtc=[DateTime]::UtcNow.ToString('o');screenshot=(Shot $Name)};foreach($key in $Data.Keys){$entry[$key]=$Data[$key]};$script:evidence.steps+=@($entry);Write-HarnessResult $directory 'capture.json' $script:evidence|Out-Null;return $entry}
function Start-Recorder([string]$Name){
 $folder=Join-Path $directory ('frames-'+$Name);[IO.Directory]::CreateDirectory($folder)|Out-Null
 $state=[hashtable]::Synchronized(@{stop=$false;frames=[Collections.ArrayList]::new();error=$null})
 $r=$window.Current.BoundingRectangle;$area=@([int]$r.X,[int]$r.Y,[int]$r.Width,[int]$r.Height)
 $shell=[powershell]::Create()
 $null=$shell.AddScript({param($state,$folder,$area)
  Add-Type -AssemblyName System.Drawing
  $codec=[Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()|Where-Object MimeType -eq 'image/jpeg'
  $quality=[Drawing.Imaging.EncoderParameters]::new(1);$quality.Param[0]=[Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality,[long]80)
  $clock=[Diagnostics.Stopwatch]::StartNew();$n=0
  try{while(-not$state.stop){$n++;$file=('frame-{0:D5}.jpg' -f $n);$b=[Drawing.Bitmap]::new($area[2],$area[3]);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen($area[0],$area[1],0,0,$b.Size);$b.Save((Join-Path $folder $file),$codec,$quality)}finally{$g.Dispose();$b.Dispose()};[void]$state.frames.Add(@{file=$file;at=[Math]::Round($clock.Elapsed.TotalSeconds,3)});Start-Sleep -Milliseconds 200}}catch{$state.error=$_.Exception.Message}
 }).AddArgument($state).AddArgument($folder).AddArgument($area)
 return @{shell=$shell;handle=$shell.BeginInvoke();state=$state;folder=$folder;name=$Name}
}
function Stop-Recorder($Recorder){
 if(-not$Recorder){return}
 $Recorder.state.stop=$true;$Recorder.shell.EndInvoke($Recorder.handle)|Out-Null;$Recorder.shell.Dispose()
 $frames=@($Recorder.state.frames);for($i=0;$i -lt $frames.Count;$i++){$frames[$i].duration=if($i+1 -lt $frames.Count){[Math]::Round($frames[$i+1].at-$frames[$i].at,3)}else{0.2}}
 Write-HarnessResult $directory ('frames-'+$Recorder.name+'.json') @{frames=$frames;error=$Recorder.state.error}|Out-Null
}
function Fixture([string]$Name){$folder=Join-Path $directory $Name;[IO.Directory]::CreateDirectory($folder)|Out-Null;$script:roots.Add($folder);return $folder}
function Watch-Texts([double]$Limit,[scriptblock]$Done){
 $seen=[Collections.Generic.List[object]]::new();$clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.Elapsed.TotalSeconds -lt $Limit){
  $row=@($window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'GameSessionProfileStatus'))|ForEach-Object {$_.Current.Name})
  $now=[ordered]@{at=[Math]::Round($clock.Elapsed.TotalSeconds,2);row=($row -join ' | ');status=(Text 'GameSessionStatus')}
  if($seen.Count -eq 0 -or $seen[$seen.Count-1].row -cne $now.row -or $seen[$seen.Count-1].status -cne $now.status){$seen.Add($now)}
  if(& $Done){break}
  Start-Sleep -Milliseconds 100
 }
 return ,$seen.ToArray()
}
function Open-GamesTab{
 # The self-contained build counts as a release build and opens on Home: pick Games in the menu when the tab isn't showing.
 $tab=$null;try{$tab=WaitFor {ById 'GamesTab'} 15 'the Games tab'}catch{}
 if(-not $tab){
  $nav=WaitFor {@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Games'))|Where-Object {$_.Current.ControlType -eq $CT::ListItem})[0]} 60 'Games in the menu'
  try{$nav.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}catch{$nav.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
  $tab=WaitFor {ById 'GamesTab'} 120 'the Games tab'
 }
 Start-Sleep -Seconds 2
 $skip=ById 'UpdateLaterButton';if($skip){Invoke $skip}
 $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Seconds 1
}
# Only a real window counts: a tooltip the app shows (such as Close Navigation under a resting mouse) is a top-level element too.
function AppWindow([int]$Id){$A::RootElement.FindFirst($TS::Children,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$Id),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Window)))}
function ProfileState{
 $saved=@([IO.Directory]::GetDirectories($operations,'launch-profile-*')|Where-Object {$before -notcontains $_})
 if($saved.Count -ne 1){return $null}
 $file=Join-Path $saved[0] 'state.json';if([IO.File]::Exists($file)){[IO.File]::ReadAllText($file)|ConvertFrom-Json}
}
function Next-Launcher([string]$Name){
 # Close the running launcher, open a new one and wait until the saved settings turned on for it, with their launch priorities.
 [IO.File]::WriteAllText((Join-Path $script:launcherRoot 'stop-launcher'),'')
 WaitFor {-not(Get-Process -Name 'RooIndustriesSavedLauncher' -ErrorAction SilentlyContinue)} 30 'the launcher to close'|Out-Null
 WaitFor {-not(Test-Path -LiteralPath $ifeo)} 60 'the closed launcher''s session to put its launch priorities back'|Out-Null
 $script:launcherRoot=Fixture ('launcher-'+$Name)
 $launcher=Start-OwnedProcess $launcherPath ('--launcher "'+$script:launcherRoot+'"') 'Hidden' 'saved-launcher-fixture';$script:owned.Add($launcher)
 WaitFor {Test-Path -LiteralPath (Join-Path $script:launcherRoot 'launcher-ready.json')} 30 'the launcher fixture'|Out-Null
 try{return WaitFor {$state=ProfileState;if($state -and $state.status -eq 'armed' -and $state.launcher.processId -eq [int]$launcher.Identity.pid -and (Test-Path -LiteralPath $ifeo)){$state}} 90 ('the saved settings to turn on for the next launcher run ('+$Name+')')}
 catch{return $null}
}
function Setup([string]$Game=$gamePath){
 Invoke (WaitFor {Enabled 'GameSessionNew'} 60 'New on Games');Start-Sleep -Milliseconds 500
 (WaitFor {Enabled 'GameSessionExecutable'} 60 'the game file box').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Game);Start-Sleep -Milliseconds 500
 Invoke (WaitFor {Enabled 'GameSessionRefresh'} 30 'Refresh on Games')
 $choice=Choose (WaitFor {Enabled 'GameSessionLauncher'} 60 'the launcher list') {param($n) $n -like ([IO.Path]::GetFileNameWithoutExtension($launcherPath)+'*')} 'the launcher fixture'
 $preset=Choose (WaitFor {Enabled 'GameSessionPreset'} 60 'the preset list') {param($n) $n -like 'Balanced*'} 'the Balanced preset'
 return @{launcher=$choice;preset=$preset}
}
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App','RooIndustriesSavedLauncher','RooIndustriesSavedGame' -ErrorAction SilentlyContinue).Count){throw 'The app or a fixture with the same name is already running; this capture needs them closed.'}
 $dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count -gt 0})
 if(-not$dotnet){throw 'No .NET SDK was found for the test build.'};$dotnet=$dotnet[0]
 $env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:DOTNET_ROOT_X64=$env:DOTNET_ROOT
 Initialize-HarnessBuildFolders $Source
 foreach($folder in 'artifacts','backend\bin'){Ensure-HarnessOutputDirectory (Join-Path $Source $folder)}
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Source 'backend\scripts\Build-OptimizerHost.ps1') -DotNetPath $dotnet *>> $build
 if($LASTEXITCODE -ne 0){throw 'The helper build failed; see build.log.'}
 $bin=Join-Path $Source 'tools\validation\ProtectedSessions\bin\publish'
 & $dotnet publish (Join-Path $Source 'tools\validation\ProtectedSessions\ProtectedSessions.csproj') -c Release -o $bin -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The fixture build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 # Self-contained like the release: the sign-in start runs the app through the clean launcher, which clears DOTNET_ROOT.
 # Like the release build, the Windows App SDK's own files go to a short folder to stay under the 260-character path limit.
 & $dotnet build $project --configuration Debug -p:Platform=x64 -r win-x64 --self-contained -p:WindowsAppSDKSelfContained=true ('-p:SelfContainedIntermediateOutputPath='+(Join-Path $Source 'artifacts\wsdk')+'/') --disable-build-servers -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app build produced no executable.'}
 $probe=Join-Path $bin 'RooIndustriesLaunchPolicyProbe.exe'
 $gamePath=Join-Path $bin 'RooIndustriesSavedGame.exe';$launcherPath=Join-Path $bin 'RooIndustriesSavedLauncher.exe'
 $copies.Add((Copy-HarnessFile $probe $gamePath 'saved-game-fixture'));$copies.Add((Copy-HarnessFile $probe $launcherPath 'saved-launcher-fixture'))
 if(Test-Path -LiteralPath $ifeo){throw 'The fixture game already has launch priorities; this capture needs them absent.'}

 $env:ROO_INDUSTRIES_INITIAL_NAV='profiles';$env:ROO_INDUSTRIES_BACKEND_ROOT=$Source;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {AppWindow ([int]$app.Identity.pid)} 180 'the app window'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 [RooIndustriesSavedSettingsUi]::SetWindowPos($hwnd,[IntPtr]::new(-1),20,20,1400,1000,0x40)|Out-Null;[RooIndustriesSavedSettingsUi]::SetForegroundWindow($hwnd)|Out-Null
 Open-GamesTab

 $launcherRoot=Fixture 'launcher'
 $owned.Add((Start-OwnedProcess $launcherPath ('--launcher "'+$launcherRoot+'"') 'Hidden' 'saved-launcher-fixture'))
 WaitFor {Test-Path -LiteralPath (Join-Path $launcherRoot 'launcher-ready.json')} 30 'the launcher fixture'|Out-Null
 if($Scenario -eq 'link-review'){
 # Settings an earlier version saved for a game picked through a folder junction kept the junction path. They must not turn on, and the row must say why.
 $link=Join-Path $directory 'game-link'
 & (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') /d /c mklink /J "$link" "$bin"|Out-Null
 if($LASTEXITCODE -ne 0){$link=$null;throw 'The folder junction to the game could not be made.'}
 $legacyGame=Join-Path $link ([IO.Path]::GetFileName($gamePath))
 Setup $legacyGame|Out-Null
 Toggle (WaitFor {Enabled 'GameSessionKeep'} 30 'Save for next time') $true
 Invoke (WaitFor {Enabled 'GameSessionPreview'} 60 'Review changes')
 WaitFor {Text 'GameSessionReview'} 120 'the review'|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionStart'} 60 'Start')
 WaitFor {(Text 'GameSessionStatus') -like 'Ready*'} 120 'the session to be ready'|Out-Null
 WaitFor {ById 'GameSessionProfileStatus'} 60 'the saved settings row'|Out-Null
 [IO.File]::WriteAllText((Join-Path $launcherRoot 'stop-launcher'),'')
 WaitFor {-not(Get-Process -Name 'RooIndustriesSavedLauncher' -ErrorAction SilentlyContinue)} 30 'the launcher to close'|Out-Null
 WaitFor {-not(Test-Path -LiteralPath $ifeo)} 60 'the closed launcher''s session to put its launch priorities back'|Out-Null
 $profileRoot=@([IO.Directory]::GetDirectories($operations,'launch-profile-*')|Where-Object {$before -notcontains $_})
 if($profileRoot.Count -ne 1){throw 'Save for next time did not save one set of launch settings.'}
 $savedPreview=Join-Path $profileRoot[0] 'reviewed-preview.json';$profileFile=Join-Path $profileRoot[0] 'profile.json'
 $realGame=([IO.File]::ReadAllText($savedPreview)|ConvertFrom-Json).gamePath
 Expect 'saved' ($realGame -ieq $gamePath) 'settings saved for a game picked through a junction keep its real path'
 $json={param($value) ($value|ConvertTo-Json).Trim('"')}
 $utf8=[Text.UTF8Encoding]::new($false)
 [IO.File]::WriteAllText($savedPreview,[IO.File]::ReadAllText($savedPreview).Replace('"'+(& $json $realGame)+'"','"'+(& $json $legacyGame)+'"'),$utf8)
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($savedPreview))).Replace('-','')}finally{$sha.Dispose()}
 [IO.File]::WriteAllText($profileFile,([regex]'"reviewHash": "[0-9A-Fa-f]{64}"').Replace([IO.File]::ReadAllText($profileFile),'"reviewHash": "'+$hash+'"',1),$utf8)
 if(([IO.File]::ReadAllText($savedPreview)|ConvertFrom-Json).gamePath -cne $legacyGame -or ([IO.File]::ReadAllText($profileFile)|ConvertFrom-Json).reviewHash -cne $hash){throw 'The saved settings could not be rewritten the way an earlier version saved them.'}
 $launcherRoot=Fixture 'launcher-legacy'
 $owned.Add((Start-OwnedProcess $launcherPath ('--launcher "'+$launcherRoot+'"') 'Hidden' 'saved-launcher-fixture'))
 WaitFor {Test-Path -LiteralPath (Join-Path $launcherRoot 'launcher-ready.json')} 30 'the launcher fixture'|Out-Null
 WaitFor {(Text 'GameSessionProfileStatus') -like 'Not turned on this time*'} 120 'the saved settings row to ask for a fresh review'|Out-Null
 Start-Sleep -Seconds 1
 $review=Step 'link-review' @{row=(Text 'GameSessionProfileStatus');status=(Text 'GameSessionStatus');launchPriorities=(Test-Path -LiteralPath $ifeo)}
 Expect 'link-review' ($review.row -ceq ('Not turned on this time. These settings were saved for '+$legacyGame+', but Windows now finds the game at '+$realGame+'. Turn these off and set the game up again.')) 'the row says where Windows now finds the game and how to set it up again'
 Expect 'link-review' (-not $review.launchPriorities) 'settings that need a fresh review change nothing'
 Invoke (WaitFor {Enabled 'GameSessionProfileOff'} 30 'Turn off and restore')
 WaitFor {-not(ById 'GameSessionProfileStatus') -and (Text 'GameSessionStatus') -like 'Saved settings turned off*'} 60 'the saved settings to turn off'|Out-Null
 Step 'link-review-off' @{status=(Text 'GameSessionStatus')}|Out-Null
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();$window=$null
 Expect 'closed' ($app.process.WaitForExit(30000)) 'with no saved settings left, closing the window ends the app'
 }else{
 $picked=Setup
 Toggle (WaitFor {Enabled 'GameSessionKeep'} 30 'Save for next time') $true
 Invoke (WaitFor {Enabled 'GameSessionPreview'} 60 'Review changes')
 WaitFor {Text 'GameSessionReview'} 120 'the review'|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionStart'} 60 'Start')
 WaitFor {(Text 'GameSessionStatus') -like 'Ready*'} 120 'the session to be ready'|Out-Null
 WaitFor {ById 'GameSessionProfileStatus'} 60 'the saved settings row'|Out-Null
 Start-Sleep -Seconds 1
 Step 'saved-ready' @{launcher=$picked.launcher;preset=$picked.preset;row=(Text 'GameSessionProfileStatus');status=(Text 'GameSessionStatus')}|Out-Null

 # Saved settings turn on without the window too: after it closes, and after a restart, through a sign-in start.
 $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $signIn=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like 'Performance Vertex Utility Saved Launch Settings *' -and $_.Description -ieq ('Performance Vertex Utility saved launch settings | '+$owner+' | '+$operations)})
 $startsApp=$signIn.Count -eq 1 -and "$($signIn[0].Actions[0].Arguments)".Contains($exe[0].FullName+'?--saved-settings') -and [string]$signIn[0].Principal.RunLevel -eq 'Highest' -and
  @($signIn[0].Triggers).Count -eq 1 -and $signIn[0].Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'
 Step 'sign-in-start' @{tasks=@($signIn|ForEach-Object {$_.TaskName});startsApp=$startsApp}|Out-Null
 if(-not $startsApp){throw 'Save for next time did not add a sign-in start that runs this app with --saved-settings.'}
 # The sign-in task runs elevated, so it never points at a program other programs could change.
 $unsafe=Join-Path $env:TEMP ('roo-industries-sign-in-'+[Guid]::NewGuid().ToString('N')+'.exe');[IO.File]::Copy($probe,$unsafe)
 try{& (Join-Path $Source 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action WatchAtSignIn -AppPath $unsafe -OperationsRoot $operations -ConfirmApply|Out-Null;$refused=''}
 catch{$refused=$_.Exception.Message}finally{[IO.File]::Delete($unsafe)}
 $kept="$((Get-ScheduledTask -TaskName $signIn[0].TaskName).Actions[0].Arguments)".Contains($exe[0].FullName+'?--saved-settings')
 Step 'sign-in-start-refused' @{refused=$refused;kept=$kept}|Out-Null
 Expect 'sign-in-start' ($refused.Contains('other programs could change it') -and $kept) 'the sign-in start refuses a program in a folder other programs can change, and keeps pointing at the app'
 $firstPid=[int]$app.Identity.pid
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();$window=$null
 WaitFor {-not(AppWindow $firstPid)} 30 'the window to close'|Out-Null
 Start-Sleep -Seconds 3
 Expect 'window-closed' (-not $app.process.HasExited) 'closing the window keeps the app running while saved settings are on'
 $closedRun=Next-Launcher 'window-closed'
 $evidence.steps+=@([ordered]@{step='window-closed';atUtc=[DateTime]::UtcNow.ToString('o');running=(-not $app.process.HasExited);armed=[bool]$closedRun})
 Expect 'window-closed' ($closedRun -and -not(AppWindow $firstPid)) 'with the window closed, the next launcher run gets the saved settings'
 # Opening the app again brings a window back to the same copy, and closing that one keeps the copy running too.
 $again=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-reopen' -Lifetime invocation
 $back=WaitFor {AppWindow $firstPid} 120 'the window to come back'
 Expect 'window-back' ($again.process.WaitForExit(30000) -and -not $app.process.HasExited) 'opening the app again shows a window in the copy that kept running'
 $back.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 WaitFor {-not(AppWindow $firstPid)} 30 'the second window to close'|Out-Null
 Start-Sleep -Seconds 2
 Expect 'window-back' (-not $app.process.HasExited) 'closing the window a second time keeps the app running too'
 # A restart ends every program; at sign-in Windows runs the sign-in start, and nobody opens the app.
 [IO.File]::WriteAllText((Join-Path $launcherRoot 'stop-launcher'),'')
 WaitFor {-not(Get-Process -Name 'RooIndustriesSavedLauncher' -ErrorAction SilentlyContinue)} 30 'the launcher to close'|Out-Null
 WaitFor {-not(Test-Path -LiteralPath $ifeo)} 60 'the closed launcher''s session to put its launch priorities back'|Out-Null
 Stop-HarnessProcess $app;$app=$null
 # Someone opened the app without administrator rights before the sign-in start ran. That copy can't turn saved settings on.
 # runas /trustlevel gives a token whose Administrators membership is deny-only; on a PC with UAC turned off it still runs
 # elevated, and then this part is recorded as not possible here instead of checked.
 $limitedTask='RooIndustriesSavedSettingsLimited_'+[Guid]::NewGuid().ToString('N')
 Register-ScheduledTask -TaskName $limitedTask -Action (New-ScheduledTaskAction -Execute (Join-Path ([Environment]::SystemDirectory) 'runas.exe') -Argument ('/trustlevel:0x20000 "'+$exe[0].FullName+'"')) -Principal (New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -LogonType Interactive -RunLevel Limited)|Out-Null
 try{Start-ScheduledTask -TaskName $limitedTask;$limited=WaitFor {@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue|Where-Object {$_.Path -ieq $exe[0].FullName})[0]} 60 'the copy without administrator rights'}
 finally{Unregister-ScheduledTask -TaskName $limitedTask -Confirm:$false}
 $limitedWindow=WaitFor {AppWindow $limited.Id} 120 'the window of the copy without administrator rights'
 $restricted=-not [RooIndustriesSavedSettingsUi]::Elevated($limited.Id)
 if(-not $restricted){$evidence.steps+=@([ordered]@{step='not-admin';atUtc=[DateTime]::UtcNow.ToString('o');checked=$false;why='this PC runs every copy elevated (UAC is off)'});$limited.Kill();[void]$limited.WaitForExit(15000);$limited=$null}
 Start-ScheduledTask -TaskName $signIn[0].TaskName
 $started=WaitFor {@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue|Where-Object {$_.Path -ieq $exe[0].FullName -and (-not $limited -or $_.Id -ne $limited.Id)})[0]} 60 'the sign-in start to run the app'
 $app=Register-HarnessStartedProcess $started 'suite-sign-in-start' 'invocation'
 Start-Sleep -Seconds 8
 if($restricted){Expect 'not-admin' (-not $started.HasExited) 'the sign-in start keeps going while a copy without administrator rights is open'}
 $signInRun=Next-Launcher 'sign-in'
 $evidence.steps+=@([ordered]@{step='sign-in';atUtc=[DateTime]::UtcNow.ToString('o');armed=[bool]$signInRun;window=[bool](AppWindow $started.Id)})
 Expect 'sign-in' ($signInRun -and -not(AppWindow $started.Id)) 'after the sign-in start, with no window open, the next launcher run gets the saved settings'
 if($restricted){
  $limitedWindow.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
  Expect 'not-admin' ($limited.WaitForExit(30000)) 'a copy without administrator rights ends when its window closes, even with saved settings on'
  # The sign-in copy then takes the single-window key, so the launches below hand over to it.
  Start-Sleep -Seconds 8
 }
 # Saving again, or opening the app, keeps the sign-in start as it is, so the copy it started keeps running.
 & (Join-Path $Source 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action WatchAtSignIn -AppPath $exe[0].FullName -OperationsRoot $operations -ConfirmApply|Out-Null
 Start-Sleep -Seconds 3
 Expect 'sign-in' (-not $started.HasExited -and (Get-ScheduledTask -TaskName $signIn[0].TaskName).State -eq 'Running') 'keeping the sign-in start on again leaves the copy it started running'
 # Opening the app hands over to that copy, which shows its window.
 $second=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-second-open' -Lifetime invocation
 $window=WaitFor {AppWindow $started.Id} 120 'the running copy to show its window'
 Expect 'reopened' ($second.process.WaitForExit(30000)) 'opening the app again hands over to the running copy'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 [RooIndustriesSavedSettingsUi]::SetWindowPos($hwnd,[IntPtr]::new(-1),20,20,1400,1000,0x40)|Out-Null;[RooIndustriesSavedSettingsUi]::SetForegroundWindow($hwnd)|Out-Null
 Open-GamesTab
 WaitFor {(Text 'GameSessionProfileStatus') -like 'Ready*'} 60 'the saved settings row to say Ready'|Out-Null
 Step 'reopened' @{row=(Text 'GameSessionProfileStatus');status=(Text 'GameSessionStatus')}|Out-Null

 $recorder=Start-Recorder 'turn-off'
 Invoke (WaitFor {Enabled 'GameSessionProfileOff'} 30 'Turn off and restore')
 $texts=Watch-Texts 30 {-not(ById 'GameSessionProfileStatus') -and (Text 'GameSessionStatus') -like 'Saved settings turned off*'}
 Start-Sleep -Milliseconds 600
 Stop-Recorder $recorder;$recorder=$null
 $flash=@($texts|Where-Object {$_.row -like 'Turned off, but*'}).Count -gt 0
 $off=Step 'turned-off' @{texts=$texts;flashed=$flash;status=(Text 'GameSessionStatus');detail=(Text 'GameSessionDetail');launchPriorities=(Test-Path -LiteralPath $ifeo)}
 Expect 'turned-off' (-not $flash -and $off.status -ceq 'Saved settings turned off' -and -not $off.launchPriorities) 'turning off finished cleanly, without a flash, and the game has no launch priorities left'
 Expect 'turned-off' (-not(Get-ScheduledTask -TaskName $signIn[0].TaskName -ErrorAction SilentlyContinue)) 'turning off the last saved settings removes the sign-in start'

 $sha=[Security.Cryptography.SHA256]::Create()
 $prefix=[regex]::Match([IO.File]::ReadAllText((Join-Path $Source 'backend\native\Optimizer.Core\BrandCompatibility.cs')),'LaunchMutexPrefix = "(.+?)";').Groups[1].Value.Replace('\\','\')
 if(-not$prefix){throw 'The launch settings lock name was not found in the source.'}
 try{$name=$prefix+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('ROOINDUSTRIESSAVEDGAME.EXE')))).Replace('-','')}finally{$sha.Dispose()}
 $created=$false;$imageLock=[Threading.Mutex]::new($true,$name,[ref]$created)
 if(-not$created){throw 'Another owner already holds the fixture game''s launch settings.'}
 Setup|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionPreview'} 60 'Review changes for the refused start')
 WaitFor {Text 'GameSessionReview'} 120 'the second review'|Out-Null
 $clock=[Diagnostics.Stopwatch]::StartNew()
 Invoke (WaitFor {Enabled 'GameSessionStart'} 60 'Start for the refused start')
 WaitFor {(Text 'GameSessionStatus') -like '*attention*' -or (Text 'GameSessionStatus') -like 'Ready*'} 90 'the refused start to finish'|Out-Null
 $seconds=[Math]::Round($clock.Elapsed.TotalSeconds,1)
 Start-Sleep -Milliseconds 600
 $refused=Step 'start-refused' @{seconds=$seconds;status=(Text 'GameSessionStatus');detail=(Text 'GameSessionDetail');leftovers=(Leftovers)}
 Expect 'start-refused' ($refused.status -like '*attention*' -and "$($refused.detail)".Contains("Another session owns this game's launch settings.")) 'the Games tab shows the refusal and its reason'
 Expect 'start-refused' ($seconds -lt 30) ('it took '+$seconds+' seconds to fail; a refused start should fail right away')
 Expect 'start-refused' ($refused.leftovers.Count -eq 0) ('it left '+($refused.leftovers -join ', '))
 $imageLock.ReleaseMutex();$imageLock.Dispose();$imageLock=$null

 Setup|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionPreview'} 60 'Review changes before the launcher closes')
 WaitFor {Text 'GameSessionReview'} 120 'the third review'|Out-Null
 [IO.File]::WriteAllText((Join-Path $launcherRoot 'stop-launcher'),'')
 WaitFor {-not(Get-Process -Name 'RooIndustriesSavedLauncher' -ErrorAction SilentlyContinue)} 30 'the launcher to close'|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionStart'} 60 'Start after the launcher closed')
 WaitFor {(Text 'GameSessionStatus') -like '*attention*' -or (Text 'GameSessionStatus') -like 'Ready*'} 90 'the start after the launcher closed to finish'|Out-Null
 Start-Sleep -Milliseconds 600
 $closed=Step 'launcher-closed' @{status=(Text 'GameSessionStatus');detail=(Text 'GameSessionDetail');leftovers=(Leftovers)}
 Expect 'launcher-closed' ($closed.status -like '*attention*' -and "$($closed.detail)".Contains('The launcher you picked has closed.')) 'the Games tab says the launcher closed'
 Expect 'launcher-closed' ($closed.leftovers.Count -eq 0) ('it left '+($closed.leftovers -join ', '))
 # A start whose request outlived its sign-in task, as Start leaves it if it stops before saving anything, or an older version left it.
 $endedOperation=Join-Path $operations ('game-session-'+[Guid]::NewGuid().ToString('N'));$endedRoot=Join-Path $endedOperation 'session'
 [IO.Directory]::CreateDirectory($endedRoot)|Out-Null
 [IO.File]::WriteAllText((Join-Path $endedRoot 'worker-request.json'),(@{schemaVersion=1;repoRoot=$Source;sessionRoot=$endedRoot;previewPath=(Join-Path $endedOperation 'preview.json');reviewHash='';confirm=$true}|ConvertTo-Json))
 Invoke (WaitFor {Enabled 'GameSessionRefresh'} 60 'Refresh on Games');Start-Sleep -Seconds 2
 $entry=Choose (WaitFor {Enabled 'GameSessionHistory'} 60 'the session list') {param($n) $n -like ([IO.Path]::GetFileName($endedOperation)+' ·*')} 'the start that never got going'
 Start-Sleep -Seconds 3
 $endedStep=Step 'ended-start' @{entry=$entry;status=(Text 'GameSessionStatus');detail=(Text 'GameSessionDetail')}
 Expect 'ended-start' ($entry -like "* · didn't start" -and $endedStep.status -ceq "Didn't start · nothing was changed") 'the list and the status say the start didn''t start and changed nothing'
 # With no saved settings left, closing the window ends the app.
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();$window=$null
 Expect 'closed' ($app.process.WaitForExit(30000)) 'with no saved settings left, closing the window ends the app'
 }
 if($evidence.unexpected.Count){throw ('Unexpected: '+($evidence.unexpected -join '; '))}
 $status='pass'
}catch{
 $evidence.error=$_.Exception.Message
 if($window){try{Step 'failure' @{}|Out-Null}catch{}}
}finally{
 if($imageLock){try{$imageLock.ReleaseMutex()}catch{};$imageLock.Dispose()}
 if($link -and [IO.Directory]::Exists($link)){try{[IO.Directory]::Delete($link)}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 try{Stop-Recorder $recorder}catch{$evidence.recorderError=$_.Exception.Message}
 foreach($folder in $roots){if([IO.Directory]::Exists($folder)){[IO.File]::WriteAllText((Join-Path $folder 'stop-launcher'),'')}}
 Start-Sleep -Seconds 3
 if($limited -and -not $limited.HasExited){try{$limited.Kill()}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 if($app -and -not $app.process.HasExited){try{$window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app}}catch{try{Stop-HarnessProcess $app}catch{$evidence.cleanupError+=@($_.Exception.Message)}}}
 foreach($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like 'Performance Vertex Utility Saved Launch Settings *' -and $_.Description -ieq ('Performance Vertex Utility saved launch settings | '+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+' | '+$operations)})){$evidence.leftTasks+=@($task.TaskName);try{Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 foreach($process in $owned){try{if(-not$process.process.WaitForExit(15000)){Stop-HarnessProcess $process}}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 $created=@(if([IO.Directory]::Exists($operations)){[IO.Directory]::GetDirectories($operations)|Where-Object {$before -notcontains $_ -and [IO.Path]::GetFileName($_) -match '^(game-session|launch-profile)-'}})
 $evidence.createdOperations=@($created|ForEach-Object {[IO.Path]::GetFileName($_)})
 foreach($folder in $created){
  $session=Join-Path $folder 'session'
  if([IO.Directory]::Exists($session)){
   $state=Join-Path $session 'session.json'
   if([IO.File]::Exists($state)){
    try{$recovered=& (Join-Path $Source 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action Recover -SessionRoot $session -DotNetPath $dotnet -ConfirmApply|ConvertFrom-Json}catch{$evidence.cleanupError+=@('recover '+$session+': '+$_.Exception.Message);continue}
    # Keep the operation and its task when recovery didn't finish, so its saved state stays recoverable.
    if($recovered.data.worker.restored -ne $true){$evidence.cleanupError+=@('recover '+$session+': not restored');continue}
   }
   $task=TaskName $session
   if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){$evidence.leftTasks+=@($task);try{Unregister-ScheduledTask -TaskName $task -Confirm:$false}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
  }
 }
 foreach($copy in $copies){try{Remove-HarnessEntry $copy}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 if(Test-Path -LiteralPath $ifeo){$evidence.cleanupError+=@('The fixture game still has launch priorities after cleanup.')}
 $settled=-not$evidence.cleanupError
 if($evidence.leftTasks){$status='fail'}
 foreach($folder in $created){if($settled){try{[IO.Directory]::Delete($folder,$true)}catch{$settled=$false;$evidence.cleanupError+=@($_.Exception.Message)}}}
 $evidence.removedOperations=$settled
 if(-not$settled){$status='fail'}
 $evidence.status=$status
 Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
 Write-Output ('ROO_INDUSTRIES_SAVED_SETTINGS_UI '+$status+' '+$directory)
}
if($status -ne 'pass'){exit 1}
