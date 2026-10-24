param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Source=[IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath,$Source))
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
$nonce=Initialize-HarnessInvocation ('launch-presets-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('launch-presets-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesPresetCapture {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
[RooIndustriesPresetCapture]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$catalog=([IO.File]::ReadAllText((Join-Path $Source 'backend\catalogs\launch-presets.json'))|ConvertFrom-Json).presets
$names=[ordered]@{cpuPriority='CPU priority';ioPriority='Disk priority';memoryPriority='Memory priority';gpuPriority='GPU priority';executionQoS='Power mode';priorityBoost='Priority boost'}
$labels=@{
 cpuPriority=@{Idle='Idle';BelowNormal='Below normal';Normal='Normal';AboveNormal='Above normal';High='High'}
 ioPriority=@{'0'='Very low';'1'='Low';'2'='Normal'}
 memoryPriority=@{'1'='Very low';'2'='Low';'3'='Medium';'4'='Below normal';'5'='Normal'}
 gpuPriority=@{'0'='Idle';'1'='Below normal';'2'='Normal';'3'='Above normal';'4'='High'}
 executionQoS=@{systemManaged='Windows managed';eco='Eco';high='High performance'}
 priorityBoost=@{'True'='On';'False'='Off'}
}
$starterHint='Pick one to fill in the settings below. You can still change them.'
$dash=[string][char]0x2013
$evidence=[ordered]@{label=$Label;picker=$false;checks=@();shots=@();reviews=[ordered]@{};video=$null;claimedReviews=0}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 100};throw ('Timed out waiting for '+$What)}
function ById([string]$Id){$window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Combo([string]$Name){$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$Name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ComboBox)))}
function Activate($Element){if(-not$Element){throw 'Missing UI element'};try{$Element.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{};try{$Element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();return}catch{};$Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function InvokeId([string]$Id){Activate (WaitFor {$e=ById $Id;if($e -and $e.Current.IsEnabled){$e}} 90 $Id)}
function SetText([string]$Id,[string]$Value){(WaitFor {$e=ById $Id;if($e -and $e.Current.IsEnabled){$e}} 90 $Id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Value)}
function Check([string]$Id){$p=(WaitFor {ById $Id} 45 $Id).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$p.Current.ToggleState -ne 'On'){$p.Toggle()}}
function Uncheck([string]$Id){$p=(WaitFor {ById $Id} 45 $Id).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if([string]$p.Current.ToggleState -ne 'Off'){$p.Toggle()}}
function Ticked([string]$Id){[string](ById $Id).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState}
function Shown($Box){
 try{$value=$Box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value;if($value){return $value}}catch{}
 try{$selected=@($Box.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection());if($selected.Count){return $selected[0].Current.Name}}catch{}
 $text=@($Box.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name}|Where-Object {$_ -and $_ -cne $Box.Current.Name}|Select-Object -First 1)
 if($text.Count){return $text[0]};return ''
}
function Hint{(ById 'GameSessionPresetHint').Current.Name}
function Review{$e=ById 'GameSessionReview';if($e){$e.Current.Name}else{''}}
function Picked{$shown=Shown (ById 'GameSessionPreset');if($shown -in 'Choose a preset','Custom'){''}else{$shown}}
function Placeholder{@((ById 'GameSessionPreset').FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name})}
function Settings{$shown=[ordered]@{};foreach($key in $names.Keys){$shown[$key]=Shown (Combo $names[$key])};$shown}
function Expected($Preset){$shown=[ordered]@{};foreach($key in $names.Keys){$value=$Preset.settings.$key;$shown[$key]=if($null -eq $value){'Keep current'}else{$labels[$key][[string]$value]}};$shown}
function Same($Left,$Right){foreach($key in $names.Keys){if($Left[$key] -cne $Right[$key]){return $false}};return $true}
function Assert([string]$Name,[bool]$Passed,$Detail){$evidence.checks+=@([ordered]@{name=$Name;passed=$Passed;detail=$Detail});if(-not$Passed){throw ('Check failed: '+$Name)}}
function Choose($Box,[string]$Pattern){
 if(-not$Box){throw ('Missing dropdown for '+$Pattern)}
 $id=$Box.Current.AutomationId;$name=$Box.Current.Name
 $fresh={if($id){ById $id}else{Combo $name}}
 try{$Box.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
 $items=@(WaitFor {$open=& $fresh;$open.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand();$found=@($open.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)));if($found.Count){$found}} 60 ('choices for '+$name))
 $item=@($items|Where-Object {$_.Current.Name -like $Pattern})|Select-Object -First 1
 for($page=0;-not$item -and $page -lt 40;$page++){
  $open=& $fresh
  $scroll=@($open.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {try{$_.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable}catch{$false}})|Select-Object -First 1
  if(-not$scroll){break}
  $scroll.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Scroll([Windows.Automation.ScrollAmount]::NoAmount,[Windows.Automation.ScrollAmount]::LargeIncrement)
  Start-Sleep -Milliseconds 100
  $item=@($open.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {$_.Current.Name -like $Pattern})|Select-Object -First 1
 }
 if(-not$item){throw ('Choice missing in '+$name+': '+$Pattern)}
 $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
 Start-Sleep -Milliseconds 400
 try{(& $fresh).GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()}catch{}
}
function Shot([string]$Name){
 $r=$window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $directory ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 $evidence.shots+=@([ordered]@{name=$Name;picked=$(if($evidence.picker){Picked}else{$null});hint=$(if($evidence.picker){Hint}else{$null});settings=(Settings);review=(Review)})
}
function ClaimReviews{
 $operations=Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'
 foreach($folder in @(Get-ChildItem -LiteralPath $operations -Directory -Filter 'game-session-*' -ErrorAction SilentlyContinue|Where-Object {$_.CreationTimeUtc -ge $appStarted})){
  if(@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $folder.FullName}).Count){continue}
  $preview=Join-Path $folder.FullName 'preview.json'
  if(-not(Test-Path -LiteralPath $preview -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $folder.FullName 'session'))){continue}
  $plan=[IO.File]::ReadAllText($preview)|ConvertFrom-Json
  if($plan.launcher.processId -eq $launcher.Identity.pid -and $plan.gamePath -ieq $gamePath){Add-HarnessEntry 'folder' (Get-HarnessFolderIdentity $folder.FullName) 'game-session-review' 'invocation'|Out-Null;$evidence.claimedReviews++}
 }
}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$launcher=$null;$appStarted=$null;$window=$null;$recorder=$null;$recording=$null;$status='fail'
$stopFile=Join-Path $directory 'frames.stop'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The app is already open; this capture does not take over another window.'}
 $longest=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\obj\x64\Debug\net8.0-windows10.0.19041.0\MsixContent\WindowsAppSdk.AppxDeploymentExtensions.Desktop-EventLog-Instrumentation.dll'
 if($longest.Length -gt 259){throw ('The app build needs paths up to '+$longest.Length+' characters here; Windows allows 259. Stage the frame with a shorter --directory, such as roo-industries-a.')}
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $launcherPath=Join-Path $directory 'DemoLauncher.exe';$gamePath=Join-Path $directory 'DemoGame.exe'
 Copy-HarnessFile (Join-Path ([Environment]::SystemDirectory) 'PING.EXE') $launcherPath|Out-Null
 Copy-HarnessFile (Join-Path ([Environment]::SystemDirectory) 'PING.EXE') $gamePath|Out-Null
 $launcher=Start-OwnedProcess -FilePath $launcherPath -ArgumentList '-t 127.0.0.1' -Purpose 'launcher-fixture' -Lifetime invocation
 $env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:ROO_INDUSTRIES_INITIAL_NAV='profiles'
 $appStarted=[DateTime]::UtcNow
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid));if($w -and $w.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'GamesTab'))){$w}} 180 'the Games page'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 [RooIndustriesPresetCapture]::SetWindowPos($hwnd,[IntPtr]::new(-1),0,0,0,0,0x0003)|Out-Null
 [RooIndustriesPresetCapture]::SetForegroundWindow($hwnd)|Out-Null
 if(ById 'UpdateLaterButton'){InvokeId 'UpdateLaterButton'}
 InvokeId 'GamesTab'
 InvokeId 'GameSessionNew'
 WaitFor {$e=ById 'GameSessionExecutable';$e -and $e.Current.IsEnabled} 90 'a new game session form'|Out-Null
 SetText 'GameSessionExecutable' $gamePath
 Choose (WaitFor {ById 'GameSessionLauncher'} 60 'the launcher list') ('*PID '+$launcher.Identity.pid)
 WaitFor {$e=ById 'GameSessionAllCores';if($e -and $e.Current.IsEnabled){$e}else{$c=Combo 'CPU cores';if($c -and (Shown $c)){$c}}} 90 'the launcher cores'|Out-Null
 $evidence.picker=[bool](ById 'GameSessionPreset')
 if(-not$evidence.picker){
  $names.ioPriority='I/O priority';$labels.priorityBoost=@{'True'='Allow dynamic boosts';'False'='Disable dynamic boosts'}
  Check 'GameSessionScope'
 }
 Start-Sleep -Milliseconds 800
 Shot 'fresh'
 if(-not$evidence.picker){
  $competitive=@($catalog|Where-Object id -EQ 'competitive')[0]
  foreach($key in $names.Keys){$value=$competitive.settings.$key;if($null -ne $value){Choose (Combo $names[$key]) $labels[$key][[string]$value]}}
  Assert 'Settings chosen by hand' (Same (Settings) (Expected $competitive)) (Settings)
  Shot 'manual'
  InvokeId 'GameSessionPreview'
  $text=WaitFor {$t=Review;if($t -and (ById 'GameSessionStart').Current.IsEnabled){$t}} 90 'the review'
  $evidence.reviews.manual=$text
  Assert 'Review without a picker names no preset' ($text -notmatch 'Preset:') $text
  Start-Sleep -Milliseconds 600
  Shot 'review'
 }else{
  Assert 'A fresh form has no preset picked' ((Picked) -eq '' -and (Hint) -ceq $starterHint) @{picked=(Picked);hint=(Hint);placeholder=(Placeholder)}
  foreach($preset in $catalog){
   Choose (ById 'GameSessionPreset') $preset.name
   WaitFor {(Hint) -ceq $preset.description} 30 ($preset.name+' description')|Out-Null
   Assert ('Picking '+$preset.name+' fills its settings') ((Picked) -ceq $preset.name -and (Same (Settings) (Expected $preset))) @{picked=(Picked);settings=(Settings);expected=(Expected $preset)}
   Shot ('preset-'+$preset.id)
  }
  $competitive=@($catalog|Where-Object id -EQ 'competitive')[0]
  Choose (ById 'GameSessionPreset') $competitive.name
  WaitFor {(Hint) -ceq $competitive.description} 30 'Competitive description'|Out-Null
  Choose (Combo $names.ioPriority) 'Low'
  WaitFor {(Hint) -like 'Your own mix*'} 30 'the Custom hint'|Out-Null
  Assert 'A priority edit after a preset shows Custom' ((Picked) -eq '') @{picked=(Picked);hint=(Hint);placeholder=(Placeholder);settings=(Settings)}
  Shot 'custom'
  Choose (ById 'GameSessionPreset') $competitive.name
  WaitFor {(Hint) -ceq $competitive.description} 30 'Competitive description'|Out-Null
  $usable=@(1..9|Where-Object {$e=ById ('GameSessionCore'+$_);$e -and $e.Current.IsEnabled})
  if($usable.Count -ne 9){throw ('This capture needs a launcher that can use Cores 1 to 9; usable here: '+($usable -join ','))}
  Uncheck 'GameSessionAllCores'
  foreach($core in 1..8){Check ('GameSessionCore'+$core)}
  Start-Sleep -Milliseconds 600
  $coreState=[ordered]@{picked=(Picked);hint=(Hint);allCores=(Ticked 'GameSessionAllCores');core8=(Ticked 'GameSessionCore8');core9=(Ticked 'GameSessionCore9')}
  Assert 'A core pick after a preset keeps the preset' ((Picked) -ceq $competitive.name -and (Hint) -ceq $competitive.description -and $coreState.allCores -eq 'Off' -and $coreState.core8 -eq 'On' -and $coreState.core9 -eq 'Off') $coreState
  Shot 'cores'
  InvokeId 'GameSessionPreview'
  $text=WaitFor {$t=Review;if($t -and (ById 'GameSessionStart').Current.IsEnabled){$t}} 90 'the review'
  $evidence.reviews.cores=$text
  Assert 'Review after a core pick names the preset and Cores 1-8, with no hex mask' ($text -match ('(?m)^Preset: '+$competitive.name+'$') -and $text -match ('(?m)^Cores: 1'+$dash+'8$') -and $text -notmatch '0x') $text
  Start-Sleep -Milliseconds 600
  Shot 'review'
  ClaimReviews
  Check 'GameSessionAllCores'
  $balanced=@($catalog|Where-Object id -EQ 'balanced')[0];$streaming=@($catalog|Where-Object id -EQ 'streaming')[0]
  Choose (ById 'GameSessionPreset') $streaming.name
  WaitFor {(Hint) -ceq $streaming.description} 30 'Streaming description'|Out-Null
  Start-Sleep -Milliseconds 800
  $r=$window.Current.BoundingRectangle;$frames=Join-Path $directory 'frames';[IO.Directory]::CreateDirectory($frames)|Out-Null
  $recorder=[powershell]::Create()
  [void]$recorder.AddScript({param($x,$y,$w,$h,$dir,$stop)Add-Type -AssemblyName System.Drawing;$i=0;while(-not(Test-Path $stop) -and $i -lt 600){$b=[Drawing.Bitmap]::new($w,$h);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen($x,$y,0,0,$b.Size);$b.Save((Join-Path $dir ('frame-{0:D5}.jpg' -f $i)),[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$g.Dispose();$b.Dispose()};$i++;Start-Sleep -Milliseconds 60}}).AddArgument([int]$r.X).AddArgument([int]$r.Y).AddArgument([int]$r.Width).AddArgument([int]$r.Height).AddArgument($frames).AddArgument($stopFile)
  $clock=[Diagnostics.Stopwatch]::StartNew();$recording=$recorder.BeginInvoke()
  Start-Sleep -Milliseconds 1200
  Choose (ById 'GameSessionPreset') $balanced.name
  WaitFor {(Hint) -ceq $balanced.description} 30 'Balanced description'|Out-Null
  Start-Sleep -Milliseconds 1200
  Choose (Combo 'CPU priority') 'High'
  WaitFor {(Hint) -like 'Your own mix*'} 30 'the Custom hint'|Out-Null
  Assert 'The video shows Custom after a priority edit' ((Picked) -eq '') @{picked=(Picked);settings=(Settings)}
  Start-Sleep -Milliseconds 1200
  Choose (ById 'GameSessionPreset') $balanced.name
  WaitFor {(Hint) -ceq $balanced.description} 30 'Balanced description'|Out-Null
  Assert 'Picking Balanced again refills its settings' ((Picked) -ceq $balanced.name -and (Same (Settings) (Expected $balanced))) @{picked=(Picked);settings=(Settings)}
  Start-Sleep -Milliseconds 1200
  InvokeId 'GameSessionPreview'
  $text=WaitFor {$t=Review;if($t -and (ById 'GameSessionStart').Current.IsEnabled){$t}} 90 'the video review'
  $evidence.reviews.video=$text
  Assert 'The video review names Balanced' ($text -match ('(?m)^Preset: '+$balanced.name+'$')) $text
  try{(ById 'GameSessionReview').GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
  Start-Sleep -Milliseconds 2500
  [IO.File]::WriteAllText($stopFile,'stop');[void]$recorder.EndInvoke($recording);$recording=$null
  $evidence.video=[ordered]@{frames=@(Get-ChildItem -LiteralPath $frames -Filter '*.jpg').Count;seconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);width=[int]$r.Width;height=[int]$r.Height}
  ClaimReviews
 }
 [RooIndustriesPresetCapture]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 ClaimReviews
 $status='pass'
}catch{
 $evidence.error=$_.Exception.Message
 if($window){try{Shot 'failure'}catch{}}
 throw
}finally{
 try{
  if($recorder){if(-not(Test-Path -LiteralPath $stopFile)){[IO.File]::WriteAllText($stopFile,'stop')};if($recording){try{[void]$recorder.EndInvoke($recording)}catch{}};$recorder.Dispose()}
  if($launcher -and $appStarted){try{ClaimReviews}catch{$evidence.claimError=$_.Exception.Message}}
  if($app){Stop-HarnessProcess $app}
  if($launcher){Stop-HarnessProcess $launcher}
 }catch{
  $status='fail';$evidence.cleanupError=$_.Exception.Message
  throw
 }finally{
  $evidence.status=$status
  Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
  Write-Output ('ROO_INDUSTRIES_PRESET_CAPTURE '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
