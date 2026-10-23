param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'affinity-app' $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot 'affinity-app'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesAffinityApp {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessAffinityMask(IntPtr p,out UIntPtr mask,out UIntPtr system);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr p,int kind,ref int value,int size,IntPtr returned);
 static IntPtr Open(int pid){var h=OpenProcess(0x1000,false,pid);if(h==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();return h;}
 public static ulong Affinity(int pid){var h=Open(pid);try{UIntPtr mask,system;if(!GetProcessAffinityMask(h,out mask,out system))throw new System.ComponentModel.Win32Exception();return mask.ToUInt64();}finally{CloseHandle(h);}}
 public static int Io(int pid){var h=Open(pid);try{int value=0;var status=NtQueryInformationProcess(h,33,ref value,4,IntPtr.Zero);if(status!=0)throw new InvalidOperationException("I/O priority query failed: 0x"+status.ToString("X8"));return value;}finally{CloseHandle(h);}}
}
'@
[RooIndustriesAffinityApp]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$evidence=[ordered]@{steps=@()};$status='fail'
$app=$null;$window=$null;$recorder=$null;$owned=[Collections.Generic.List[object]]::new();$roots=[Collections.Generic.List[string]]::new()
$operations=Join-Path $env:LOCALAPPDATA 'RooIndustriesOptimizationSuite\operations'
$before=@(if([IO.Directory]::Exists($operations)){[IO.Directory]::GetDirectories($operations)})
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};throw ('Timed out waiting for '+$What)}
function ById([string]$Id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Text([string]$Id){$e=ById $Id;if($e){$e.Current.Name}else{$null}}
function Invoke($Element){if(-not$Element){throw 'Missing UI element'};try{$Element.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};$Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();Start-Sleep -Milliseconds 400}
function Enabled([string]$Id){$e=ById $Id;if($e -and $e.Current.IsEnabled){$e}}
function Toggle($Element,[bool]$On){$t=$Element.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if(($t.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) -ne $On){try{$Element.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};$t.Toggle();Start-Sleep -Milliseconds 300}}
function Choose($Box,[scriptblock]$Match,[string]$What){
 if(-not$Box){throw ('Missing list for '+$What)}
 try{$Box.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 $expand=$Box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern);$expand.Expand();Start-Sleep -Milliseconds 500
 $item=$null
 try{$container=$Box.GetCurrentPattern([Windows.Automation.ItemContainerPattern]::Pattern);$next=$null;do{$next=$container.FindItemByProperty($next,$null,$null);if($next -and (& $Match $next.Current.Name)){$item=$next}}while($next -and -not$item)}catch{}
 if(-not$item){$item=@($Box.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {& $Match $_.Current.Name})[0]}
 if(-not$item){$expand.Collapse();throw ('No choice for '+$What)}
 try{$item.GetCurrentPattern([Windows.Automation.VirtualizedItemPattern]::Pattern).Realize()}catch{}
 $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Milliseconds 400
 try{$expand.Collapse()}catch{}
 return $item.Current.Name
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
function Game([string]$Folder){$ready=Join-Path $Folder 'ready.json';$found=(WaitFor {if(Test-Path -LiteralPath $ready){(Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json).pid}} 30 'the game to start');return [int]$found}
function Close-Game([string]$Folder,[int]$GamePid){[IO.File]::WriteAllText((Join-Path $Folder 'stop'),'');WaitFor {-not(Get-Process -Id $GamePid -ErrorAction SilentlyContinue)} 20 'the game to close'|Out-Null}
function Launch([string]$LauncherRoot,[string]$Folder){[IO.File]::WriteAllText((Join-Path $LauncherRoot 'launch.json'),(@{root=$Folder}|ConvertTo-Json -Compress));WaitFor {Test-Path -LiteralPath (Join-Path $Folder 'stub-exited')} 30 'the launcher helper to hand off'|Out-Null;return Game $Folder}
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App','RooIndustriesLaunchPolicyProbe','RooIndustriesHighIoLauncher','RooIndustriesHighIoStub' -ErrorAction SilentlyContinue).Count){throw 'The app or a fixture with the same name is already running; this capture does not take it over.'}
 $dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
 if(-not$dotnet){throw 'No .NET SDK was found for the test build.'};$dotnet=$dotnet[0]
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Source 'backend\scripts\Build-OptimizerHost.ps1') -DotNetPath $dotnet *>> $build
 if($LASTEXITCODE -ne 0){throw 'The helper build failed; see build.log.'}
 $bin=Join-Path $Source 'tools\validation\ProtectedSessions\bin\publish'
 & $dotnet publish (Join-Path $Source 'tools\validation\ProtectedSessions\ProtectedSessions.csproj') -c Release -o $bin -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The fixture build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app build produced no executable.'}
 $gamePath=Join-Path $bin 'RooIndustriesLaunchPolicyProbe.exe'
 $launcherPath=Join-Path $bin 'RooIndustriesHighIoLauncher.exe';$stubPath=Join-Path $bin 'RooIndustriesHighIoStub.exe'
 Copy-HarnessFile $gamePath $launcherPath 'launcher-fixture'|Out-Null;Copy-HarnessFile $gamePath $stubPath 'stub-fixture'|Out-Null

 $probeRoot=Fixture 'processes-game'
 $owned.Add((Start-OwnedProcess $gamePath ('--high-io-game "'+$probeRoot+'"') 'Hidden' 'processes-game'))
 $probe=Game $probeRoot
 $evidence.processes=[ordered]@{pid=$probe;io=[RooIndustriesAffinityApp]::Io($probe);affinity='0x'+[RooIndustriesAffinityApp]::Affinity($probe).ToString('X')}
 $all=[RooIndustriesAffinityApp]::Affinity($probe);$bits=@(0..63|Where-Object {$all -band ([uint64]1 -shl $_)});$keep=@($bits|Select-Object -First ([Math]::Max(1,[int]($bits.Count/2))))
 $keepMask=[uint64]0;foreach($bit in $keep){$keepMask=$keepMask -bor ([uint64]1 -shl $bit)}

 $env:ROO_INDUSTRIES_INITIAL_NAV='profiles';$env:ROO_INDUSTRIES_BACKEND_ROOT=$Source;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:DOTNET_ROOT=Split-Path $dotnet -Parent
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid))} 180 'the app window'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 [RooIndustriesAffinityApp]::SetWindowPos($hwnd,[IntPtr]::new(-1),20,20,1400,1000,0x40)|Out-Null;[RooIndustriesAffinityApp]::SetForegroundWindow($hwnd)|Out-Null
 $processesTab=WaitFor {ById 'ProcessesTab'} 120 'the Processes tab';Start-Sleep -Seconds 2
 $skip=ById 'UpdateLaterButton';if($skip){Invoke $skip}

 $processesTab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Seconds 1
 $recorder=Start-Recorder 'processes'
 Invoke (WaitFor {Enabled 'ProcessRefresh'} 60 'Refresh on Processes')
 $picked=Choose (WaitFor {Enabled 'ProcessPicker'} 60 'the running app list') {param($n) $n -like ('* · PID '+$probe)} 'the test game'
 $io=WaitFor {Enabled 'ioPriority'} 60 'the I/O priority choice'
 $ioChoice=Choose $io {param($n) $n -like 'High*'} 'High I/O priority'
 $cores=ById 'ProcessCoresExpander';try{$cores.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()}catch{};Start-Sleep -Milliseconds 600
 Toggle (WaitFor {Enabled 'ProcessHardAffinity'} 30 'Restrict this app to selected CPUs') $true
 foreach($bit in $bits){if($keep -notcontains $bit){$box=WaitFor {$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,('G0 · CPU '+$bit)),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::CheckBox)))} 15 ('CPU '+$bit);Toggle $box $false}}
 $mask=WaitFor {$e=ById 'ProcessAffinityMask';if($e){$v=$e.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value;if($v -and [Convert]::ToUInt64($v.Replace('0x',''),16) -eq $keepMask){$v}}} 15 'the mask to follow the ticks'
 Step 'processes-ticked' @{picked=$picked;io=$ioChoice;mask=$mask;expectedMask='0x'+$keepMask.ToString('X')}|Out-Null
 Invoke (WaitFor {Enabled 'ProcessPreview'} 30 'Review changes')
 $review=WaitFor {$t=Text 'ProcessReview';if($t){$t}} 60 'the review'
 Step 'processes-review' @{review=$review}|Out-Null
 Invoke (WaitFor {Enabled 'ProcessApply'} 60 'Apply once')
 WaitFor {[RooIndustriesAffinityApp]::Io($probe) -eq 3 -and [RooIndustriesAffinityApp]::Affinity($probe) -eq $keepMask -and (Enabled 'ProcessRestore')} 60 'High I/O and the CPU limit on the game'|Out-Null
 Start-Sleep -Seconds 1
 Step 'processes-applied' @{status=(Text 'ProcessStatus');detail=(Text 'ProcessDetail');io=[RooIndustriesAffinityApp]::Io($probe);affinity='0x'+[RooIndustriesAffinityApp]::Affinity($probe).ToString('X')}|Out-Null
 Invoke (Enabled 'ProcessRestore')
 WaitFor {[RooIndustriesAffinityApp]::Io($probe) -eq $evidence.processes.io -and [RooIndustriesAffinityApp]::Affinity($probe) -eq $all} 60 'the original values back on the game'|Out-Null
 Start-Sleep -Seconds 1
 Step 'processes-restored' @{status=(Text 'ProcessStatus');detail=(Text 'ProcessDetail');io=[RooIndustriesAffinityApp]::Io($probe);affinity='0x'+[RooIndustriesAffinityApp]::Affinity($probe).ToString('X')}|Out-Null
 Stop-Recorder $recorder;$recorder=$null
 Close-Game $probeRoot $probe

 $launcherRoot=Fixture 'launcher'
 $owned.Add((Start-OwnedProcess $launcherPath ('--high-io-launcher "'+$launcherRoot+'"') 'Hidden' 'launcher-fixture'))
 WaitFor {Test-Path -LiteralPath (Join-Path $launcherRoot 'launcher-ready')} 30 'the launcher fixture'|Out-Null
 $launcherPid=$owned[$owned.Count-1].Identity.pid
 $controlRoot=Fixture 'games-control';$control=Launch $launcherRoot $controlRoot
 $evidence.games=[ordered]@{baselineIo=[RooIndustriesAffinityApp]::Io($control);baselineAffinity='0x'+[RooIndustriesAffinityApp]::Affinity($control).ToString('X')}
 Close-Game $controlRoot $control
 (ById 'GamesTab').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep -Seconds 1
 $recorder=Start-Recorder 'games'
 $path=WaitFor {Enabled 'GameSessionExecutable'} 60 'the game file box'
 $path.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($gamePath);Start-Sleep -Milliseconds 500
 Invoke (WaitFor {Enabled 'GameSessionRefresh'} 30 'Refresh on Games')
 $launcherChoice=Choose (WaitFor {Enabled 'GameSessionLauncher'} 60 'the launcher list') {param($n) $n -like ('* · PID '+$launcherPid)} 'the launcher fixture'
 $gameIo=WaitFor {@($window.FindAll($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'I/O priority'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ComboBox)))|Where-Object {$_.Current.AutomationId -ne 'ioPriority' -and $_.Current.IsEnabled})[0]} 30 'the game I/O priority choice'
 $gameIoChoice=Choose $gameIo {param($n) $n -like 'High*'} 'High I/O priority for the game'
 $coreChoice=Choose (WaitFor {Enabled 'GameSessionCores'} 60 'the CPU cores list') {param($n) $n -like 'Cache group 1*'} 'the first cache group'
 $advanced=ById 'GameSessionAdvanced';try{$advanced.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()}catch{};Start-Sleep -Milliseconds 600
 $groupText=WaitFor {$e=ById 'GameSessionMask';if($e){$v=$e.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value;if($v){$v}}} 15 'the chosen cache group mask'
 $groupMask=[Convert]::ToUInt64($groupText.Replace('0x','').Replace('0X',''),16)
 Toggle (WaitFor {Enabled 'GameSessionScope'} 30 'the launcher scope box') $true
 Step 'games-chosen' @{launcher=$launcherChoice;io=$gameIoChoice;cores=$coreChoice;mask=$groupText}|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionPreview'} 60 'Review changes on Games')
 $gameReview=WaitFor {$t=Text 'GameSessionReview';if($t){$t}} 120 'the session review'
 Step 'games-review' @{review=$gameReview;status=(Text 'GameSessionStatus')}|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionStart'} 60 'Start')
 WaitFor {(Text 'GameSessionStatus') -like 'Ready*'} 120 'the session to be ready'|Out-Null
 Step 'games-ready' @{status=(Text 'GameSessionStatus')}|Out-Null
  $firstRoot=Fixture 'games-first';$first=Launch $launcherRoot $firstRoot
 WaitFor {[RooIndustriesAffinityApp]::Io($first) -eq 3 -and [RooIndustriesAffinityApp]::Affinity($first) -eq $groupMask -and (Text 'GameSessionStatus') -like 'Active*'} 90 'High I/O and the cache group on the launched game'|Out-Null
 Start-Sleep -Seconds 2
 Step 'games-active' @{pid=$first;status=(Text 'GameSessionStatus');io=[RooIndustriesAffinityApp]::Io($first);affinity='0x'+[RooIndustriesAffinityApp]::Affinity($first).ToString('X')}|Out-Null
 Close-Game $firstRoot $first
 WaitFor {(Text 'GameSessionStatus') -like 'Ready*'} 60 'the session to wait for the next start'|Out-Null
 $againRoot=Fixture 'games-again';$again=Launch $launcherRoot $againRoot
 WaitFor {[RooIndustriesAffinityApp]::Io($again) -eq 3 -and [RooIndustriesAffinityApp]::Affinity($again) -eq $groupMask -and (Text 'GameSessionStatus') -like 'Active*'} 90 'High I/O and the cache group after relaunch'|Out-Null
 Start-Sleep -Seconds 2
 Step 'games-relaunched' @{pid=$again;status=(Text 'GameSessionStatus');io=[RooIndustriesAffinityApp]::Io($again);affinity='0x'+[RooIndustriesAffinityApp]::Affinity($again).ToString('X')}|Out-Null
 Invoke (WaitFor {Enabled 'GameSessionStop'} 30 'Stop and restore')
 WaitFor {(Text 'GameSessionStatus') -like 'Stopped*' -and [RooIndustriesAffinityApp]::Io($again) -eq $evidence.games.baselineIo -and ('0x'+[RooIndustriesAffinityApp]::Affinity($again).ToString('X')) -eq $evidence.games.baselineAffinity} 120 'Stop to restore the game'|Out-Null
 Start-Sleep -Seconds 2
 Step 'games-stopped' @{pid=$again;status=(Text 'GameSessionStatus');io=[RooIndustriesAffinityApp]::Io($again);affinity='0x'+[RooIndustriesAffinityApp]::Affinity($again).ToString('X')}|Out-Null
 Stop-Recorder $recorder;$recorder=$null
 Close-Game $againRoot $again
 [IO.File]::WriteAllText((Join-Path $launcherRoot 'stop-launcher'),'')
 $status='pass'
}catch{
 $evidence.error=$_.Exception.Message
 if($window){try{Step 'failure' @{}|Out-Null}catch{}}
}finally{
 try{Stop-Recorder $recorder}catch{$evidence.recorderError=$_.Exception.Message}
 foreach($folder in $roots){if([IO.Directory]::Exists($folder)){[IO.File]::WriteAllText((Join-Path $folder 'stop'),'');[IO.File]::WriteAllText((Join-Path $folder 'stop-launcher'),'')}}
 Start-Sleep -Seconds 3
 if($app){try{$window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app}}catch{try{Stop-HarnessProcess $app}catch{$evidence.cleanupError+=@($_.Exception.Message)}}}
 foreach($process in $owned){try{if(-not$process.process.WaitForExit(15000)){Stop-HarnessProcess $process}}catch{$evidence.cleanupError+=@($_.Exception.Message)}}
 $created=@(if([IO.Directory]::Exists($operations)){[IO.Directory]::GetDirectories($operations)|Where-Object {$before -notcontains $_ -and [IO.Path]::GetFileName($_) -match '^(game-session|process)-'}})
 $evidence.createdOperations=@($created|ForEach-Object {[IO.Path]::GetFileName($_)})
 $settled=$status -eq 'pass' -and -not$evidence.cleanupError
 foreach($folder in $created){if($settled){[IO.Directory]::Delete($folder,$true)}}
 $evidence.removedOperations=$settled
 $evidence.status=$status
 Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
 Write-Output ('ROO_INDUSTRIES_AFFINITY_APP '+$status+' '+$directory)
}
if($status -ne 'pass'){exit 1}
